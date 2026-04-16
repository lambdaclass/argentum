defmodule Arena.DependencyBoundaryTest do
  @moduledoc """
  Guard-rail tests to keep cross-app dependencies clean and prevent coupling
  from spreading beyond the known boundaries.

  Current dependency graph (umbrella level):
    arena  -.->  game_backend   (runtime calls, suppressed via xref excludes)
    arena  -.->  ao_session     (runtime calls, suppressed via xref excludes)
    arena  -.->  ao_tcp_gateway (runtime calls, suppressed via xref excludes)
    game_backend  -->  arena    (compile dep for Arena.Entity.PlayerEntity)
    ao_tcp_gateway -->  arena   (compile dep)

  The arena <-> game_backend relationship is a known circular dependency:
  game_backend depends on arena for the PlayerEntity struct, while arena calls
  game_backend as its persistence layer. This cannot be expressed as a Mix dep
  in both directions without creating a cycle.

  TODO: extract PlayerEntity to a shared app (e.g. ao_core) to break the cycle.

  These tests prevent the coupling from growing beyond its current bounds.
  """
  use ExUnit.Case, async: true

  @server_root Path.expand("../../../", __DIR__)

  describe "game_backend Arena references are limited to the known coupling points" do
    test "only GameBackend.Characters code references Arena.Entity.PlayerEntity" do
      game_backend_lib = Path.join(@server_root, "apps/game_backend/lib")

      {output, 0} =
        System.cmd("grep", ["-rn", "Arena\\.", game_backend_lib],
          stderr_to_stdout: true
        )

      lines = String.split(output, "\n", trim: true)

      # Separate code references from doc/comment references
      code_lines = Enum.reject(lines, &is_doc_or_comment_line?/1)

      # Every non-doc Arena reference in game_backend must be in characters.ex
      # and must reference Arena.Entity.PlayerEntity (the known coupling point).
      for line <- code_lines do
        assert line =~ "characters.ex",
               "Unexpected Arena reference outside characters.ex:\n  #{line}"

        assert line =~ "Arena.Entity.PlayerEntity",
               "Unexpected Arena module referenced in game_backend:\n  #{line}"
      end

      # There should be no more than 7 code references (currently 6 in entity
      # functions + 1 struct construction). If this grows, the coupling is
      # spreading.
      assert length(code_lines) <= 7,
             "Arena references in game_backend grew beyond expected 7 " <>
               "(found #{length(code_lines)}). " <>
               "Review whether game_backend is accumulating new Arena dependencies."
    end

    test "GameBackend.Guilds only mentions Arena in documentation strings" do
      guilds_path =
        Path.join(@server_root, "apps/game_backend/lib/game_backend/guilds.ex")

      content = File.read!(guilds_path)

      # Strip all doc heredocs and comment lines, then check for Arena references
      code_only = strip_docs_and_comments(content)

      refute code_only =~ ~r/Arena\./,
             "GameBackend.Guilds has a non-documentation Arena reference"
    end
  end

  describe "arena/mix.exs xref excludes are documented" do
    test "xref excludes have explanatory comments about why they exist" do
      mix_path = Path.join(@server_root, "apps/arena/mix.exs")
      content = File.read!(mix_path)

      if content =~ "xref:" do
        assert content =~ ~r/# .*cross-app runtime/i,
               "xref excludes in arena/mix.exs lack explanatory comments"

        # GameBackend excludes should mention the cycle / TODO
        assert content =~ ~r/# .*cycle/i,
               "xref excludes should explain the Mix dependency cycle"
      end
    end

    test "xref excludes only contain the known set of modules" do
      mix_path = Path.join(@server_root, "apps/arena/mix.exs")
      content = File.read!(mix_path)

      # Extract the exclude list
      case Regex.run(~r/exclude:\s*\[([^\]]*)\]/s, content, capture: :all_but_first) do
        [block] ->
          allowed = ~w[
            GameBackend.Account
            GameBackend.BankItems
            GameBackend.Characters
            GameBackend.Guilds
            AoTcpGateway.BrowserApi
            AoSession.OnlineDirectory
          ]

          # Extract module names from the exclude block
          modules =
            Regex.scan(~r/([A-Z][\w.]+)/, block)
            |> Enum.map(&List.first/1)

          for mod <- modules do
            assert mod in allowed,
                   "Unexpected module in xref excludes: #{mod}. " <>
                     "Add it to the allowed list in this test if intentional."
          end

        nil ->
          flunk("Could not find xref exclude list in arena/mix.exs")
      end
    end
  end

  describe "known circular dep is documented" do
    test "game_backend/mix.exs documents the arena dependency reason" do
      mix_path = Path.join(@server_root, "apps/game_backend/mix.exs")
      content = File.read!(mix_path)

      assert content =~ "KNOWN CIRCULAR DEP",
             "game_backend/mix.exs should document why it depends on arena"

      assert content =~ "PlayerEntity",
             "game_backend/mix.exs should mention PlayerEntity as the coupling point"
    end

    test "game_backend only depends on arena for PlayerEntity" do
      # This is a duplicate check from a different angle: verify at the
      # source-code level that the only Arena.* usage is PlayerEntity.
      game_backend_lib = Path.join(@server_root, "apps/game_backend/lib")

      {output, 0} =
        System.cmd("grep", ["-rn", "Arena\\.", game_backend_lib],
          stderr_to_stdout: true
        )

      code_lines =
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&is_doc_or_comment_line?/1)

      arena_modules =
        code_lines
        |> Enum.flat_map(fn line ->
          Regex.scan(~r/(Arena\.\w[\w.]*)/, line) |> Enum.map(&List.first/1)
        end)
        |> Enum.uniq()

      assert arena_modules == ["Arena.Entity.PlayerEntity"],
             "game_backend references Arena modules beyond PlayerEntity: #{inspect(arena_modules)}"
    end
  end

  # -- Helpers --

  # Returns true if the grep output line is inside a doc string or comment.
  defp is_doc_or_comment_line?(grep_line) do
    case Regex.run(~r/:\d+:\s*(.*)$/, grep_line, capture: :all_but_first) do
      [content] ->
        trimmed = String.trim(content)

        # Matches: comment lines, @moduledoc/@doc attributes, and lines
        # that are clearly inside a heredoc doc string (indented prose).
        String.starts_with?(trimmed, "#") or
          trimmed =~ ~r/^@(moduledoc|doc)/ or
          trimmed =~ ~r/^Provides .* `Arena\./ or
          trimmed =~ ~r/^[A-Z][a-z].*`Arena\./

      _ ->
        false
    end
  end

  # Strip @moduledoc/doc heredocs and comment lines from Elixir source.
  defp strip_docs_and_comments(source) do
    source
    # Remove heredoc docs: @moduledoc """ ... """ and @doc """ ... """
    |> String.replace(~r/@(?:moduledoc|doc)\s+\"\"\".*?\"\"\"/s, "")
    # Remove single-line docs: @moduledoc "..." and @doc "..."
    |> String.replace(~r/@(?:moduledoc|doc)\s+"[^"]*"/, "")
    # Remove comment lines
    |> String.replace(~r/^\s*#.*$/m, "")
  end
end
