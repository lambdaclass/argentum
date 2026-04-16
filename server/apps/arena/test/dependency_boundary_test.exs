defmodule Arena.DependencyBoundaryTest do
  @moduledoc """
  Guard-rail tests to keep cross-app dependencies clean and prevent coupling
  from spreading beyond the known boundaries.

  Current dependency graph (umbrella level):
    ao_entities          (shared struct app, no deps)
    arena       -->  ao_entities   (compile dep for AoEntities.PlayerEntity)
    game_backend -->  ao_entities  (compile dep for AoEntities.PlayerEntity)
    arena  -.->  game_backend   (runtime calls, suppressed via xref excludes)
    arena  -.->  ao_session     (runtime calls, suppressed via xref excludes)
    arena  -.->  ao_tcp_gateway (runtime calls, suppressed via xref excludes)
    ao_tcp_gateway -->  arena   (compile dep)

  The former arena <-> game_backend circular dependency has been broken by
  extracting PlayerEntity to ao_entities. These tests prevent regressions.
  """
  use ExUnit.Case, async: true

  @server_root Path.expand("../../../", __DIR__)

  describe "game_backend does NOT depend on arena" do
    test "game_backend/mix.exs does not list arena as a dependency" do
      mix_path = Path.join(@server_root, "apps/game_backend/mix.exs")
      content = File.read!(mix_path)

      # Strip comments so we only check actual dep declarations
      code_only = strip_comments(content)

      refute code_only =~ ~r/\{:arena\b/,
             "game_backend/mix.exs should not depend on :arena — use :ao_entities instead"
    end

    test "game_backend code has no Arena.* module references" do
      game_backend_lib = Path.join(@server_root, "apps/game_backend/lib")

      {output, status} =
        System.cmd("grep", ["-rn", "Arena\\.", game_backend_lib],
          stderr_to_stdout: true
        )

      if status == 0 do
        code_lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&is_doc_or_comment_line?/1)

        assert code_lines == [],
               "game_backend references Arena modules (circular dep regression):\n" <>
                 Enum.join(code_lines, "\n")
      end

      # status == 1 means no matches — that's the expected case
    end

    test "game_backend depends on ao_entities for PlayerEntity" do
      mix_path = Path.join(@server_root, "apps/game_backend/mix.exs")
      content = File.read!(mix_path)

      assert content =~ "{:ao_entities, in_umbrella: true}",
             "game_backend should depend on ao_entities"

      assert content =~ "PlayerEntity",
             "game_backend/mix.exs should mention PlayerEntity as the reason for the dep"
    end
  end

  describe "arena depends on ao_entities (not game_backend)" do
    test "arena/mix.exs lists ao_entities as a dependency" do
      mix_path = Path.join(@server_root, "apps/arena/mix.exs")
      content = File.read!(mix_path)

      assert content =~ "{:ao_entities, in_umbrella: true}",
             "arena should depend on ao_entities for PlayerEntity"
    end

    test "arena/mix.exs does NOT list game_backend as a dependency" do
      mix_path = Path.join(@server_root, "apps/arena/mix.exs")
      content = File.read!(mix_path)

      code_only = strip_comments(content)

      refute code_only =~ ~r/\{:game_backend\b/,
             "arena should not have a compile dep on game_backend (use xref excludes for runtime calls)"
    end
  end

  describe "arena/mix.exs xref excludes are documented" do
    test "xref excludes have explanatory comments about why they exist" do
      mix_path = Path.join(@server_root, "apps/arena/mix.exs")
      content = File.read!(mix_path)

      if content =~ "xref:" do
        assert content =~ ~r/# .*cross-app runtime/i,
               "xref excludes in arena/mix.exs lack explanatory comments"
      end
    end

    test "xref excludes only contain the known set of modules" do
      mix_path = Path.join(@server_root, "apps/arena/mix.exs")
      content = File.read!(mix_path)

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

  describe "ao_entities is a leaf app with no umbrella deps" do
    test "ao_entities/mix.exs has no umbrella dependencies" do
      mix_path = Path.join(@server_root, "apps/ao_entities/mix.exs")
      content = File.read!(mix_path)

      refute content =~ "in_umbrella: true",
             "ao_entities should be a leaf app with no umbrella dependencies"
    end

    test "ao_entities defines the PlayerEntity struct" do
      assert Code.ensure_loaded?(AoEntities.PlayerEntity),
             "AoEntities.PlayerEntity module should be loadable"

      assert function_exported?(AoEntities.PlayerEntity, :__struct__, 0),
             "AoEntities.PlayerEntity should define a struct"
    end
  end

  # -- Helpers --

  defp is_doc_or_comment_line?(grep_line) do
    case Regex.run(~r/:\d+:\s*(.*)$/, grep_line, capture: :all_but_first) do
      [content] ->
        trimmed = String.trim(content)

        String.starts_with?(trimmed, "#") or
          trimmed =~ ~r/^@(moduledoc|doc)/ or
          trimmed =~ ~r/^[A-Z][a-z].*`/ or
          trimmed =~ ~r/^Provides .*`/

      _ ->
        false
    end
  end

  defp strip_comments(source) do
    String.replace(source, ~r/^\s*#.*$/m, "")
  end
end
