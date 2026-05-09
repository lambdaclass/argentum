defmodule Arena.EffectsSendRawGuardTest do
  @moduledoc """
  Build-time guard: every module already on the map-layer effects
  contract must stay free of `{:send_raw, _}` emissions. Producers must
  emit canonical `Arena.Map.Effect.t()` via `Arena.Map.Effects.*`
  constructors and let the runner translate to envelopes.

  Allowlist (modules that may still emit `{:send_raw, _}` because their
  surface has not migrated yet, or because they are intentionally
  out-of-band) is documented in `server/docs/SEND_RAW_AUDIT.md`. Adding
  a new entry to the allowlist requires a corresponding entry there.

  The check walks each module's quoted AST and looks for the atom
  `:send_raw`. This sidesteps false positives from moduledoc / inline
  comment text that mentions `{:send_raw, _}` for documentation
  purposes — those become string literals in the AST, not atoms.
  """
  use ExUnit.Case, async: true

  # Paths relative to the arena app root (`apps/arena`). When run from the
  # umbrella root, ExUnit's cwd is the app, not the umbrella, so these are
  # already correct.
  @clean_modules [
    "lib/arena/map/healing.ex",
    "lib/arena/map/inventory_handlers.ex",
    "lib/arena/map/social.ex",
    "lib/arena/map/combat_handlers.ex",
    "lib/arena/map/spell_effects.ex",
    "lib/arena/map/npc_interaction.ex",
    "lib/arena/map/status_ticks.ex",
    "lib/arena/map/effects.ex",
    "lib/arena/map/visibility.ex",
    "lib/arena/map/player_death.ex",
    "lib/arena/map/npc_death.ex",
    "lib/arena/map/criminal_status.ex",
    "lib/arena/map/bank.ex",
    "lib/arena/map/banking.ex",
    "lib/arena/map/trade.ex",
    "lib/arena/npc_ai.ex"
  ]

  for module <- @clean_modules do
    test "#{module} contains no :send_raw atom emissions" do
      path = Path.expand(unquote(module), __DIR__ |> Path.dirname())
      source = File.read!(path)
      ast = Code.string_to_quoted!(source)

      {_, found} =
        Macro.prewalk(ast, [], fn
          :send_raw, acc -> {:send_raw, [unquote(module) | acc]}
          node, acc -> {node, acc}
        end)

      assert found == [],
             """
             Found a `:send_raw` atom in #{unquote(module)}, which is on
             the map-layer effects contract and must emit through
             `Arena.Map.Effects.*` constructors. Either:

               * Replace the `{:send_raw, packet}` emission with the
                 corresponding `Effects.*` call, or
               * If the producer is genuinely out-of-band, add an entry
                 to `server/docs/SEND_RAW_AUDIT.md` and remove this file
                 from the @clean_modules list.
             """
    end
  end
end
