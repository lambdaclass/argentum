defmodule Arena.RngGuardTest do
  @moduledoc """
  Build-time guard: parity-sensitive gameplay modules must route every
  random draw through `Arena.Rng` (`uniform/0`, `uniform/1`, `between/2`)
  rather than calling `:rand.uniform` / `:rand.uniform_real` or
  `Enum.random` / `Enum.shuffle` directly.

  Going through `Arena.Rng` is what lets golden/property fixtures install a
  deterministic strategy via `Process.put(:arena_test_rng, fn)` (see
  `Arena.Test.Rng`). A stray direct call silently re-introduces
  non-determinism into a formula whose output we otherwise pin to VB6.

  The allowlist — modules that legitimately keep raw RNG because their
  draws are event flavor (spawn coordinates, treasure placement, AI
  wander direction), not parity-bearing gameplay — is documented in
  `server/docs/RNG_AUDIT.md`. Adding a module to `@allowlisted` requires a
  corresponding entry there. Benchmarks and `*_property_test.exs` /
  `*_fuzz_*` suites live under `test/` and are out of scope by
  construction (this guard only scans `lib/`).

  Detection walks each module's quoted AST for the call shapes
  `:rand.uniform(...)`, `:rand.uniform_real(...)`, `Enum.random(...)`,
  and `Enum.shuffle(...)`. Because it matches AST call nodes (not text),
  mentions of these inside `@moduledoc` / comments are string literals and
  do not trip the guard — `Arena.Combat`'s docstring referencing the VB6
  formula stays legal.
  """
  use ExUnit.Case, async: true

  # Parity-sensitive modules. Every random draw here feeds a VB6-pinned
  # formula (combat damage/defense/crit, spell magnitudes, potion
  # modificador, poison ticks, hiding roll, taming/skill gates, starting
  # stamina, NPC spawn HP) and must be deterministically testable.
  @guarded [
    "lib/arena/combat.ex",
    "lib/arena/character_creation.ex",
    "lib/arena/entity/npc_entity.ex",
    "lib/arena/map/combat_handlers.ex",
    "lib/arena/map/spell_effects.ex",
    "lib/arena/map/status_ticks.ex",
    "lib/arena/map/social.ex",
    "lib/arena/map/inventory_handlers.ex",
    "lib/arena/map/npc_interaction.ex",
    "lib/arena/map/crafting.ex"
  ]

  # Allowlist: raw RNG permitted (event flavor / non-parity). Keep in sync
  # with server/docs/RNG_AUDIT.md.
  @allowlisted [
    "lib/arena/npc_ai.ex",
    "lib/arena/treasure_event.ex",
    "lib/arena/map/map_server.ex",
    "lib/arena/events/invasion_server.ex",
    "lib/arena/events/siege_server.ex",
    "lib/arena/events/tournament_server.ex"
  ]

  for module <- @guarded do
    test "#{module} routes all randomness through Arena.Rng" do
      found = direct_rng_calls(unquote(module))

      assert found == [],
             """
             Found direct RNG call(s) in #{unquote(module)}: #{inspect(found)}.

             This module is parity-sensitive: its draws feed a VB6-pinned
             formula and must be deterministically testable. Replace them:

               * `:rand.uniform()`        -> `Arena.Rng.uniform()`
               * `:rand.uniform(n)`       -> `Arena.Rng.uniform(n)`
               * `Enum.random(min..max)`  -> `Arena.Rng.between(min, max)`

             If this draw is genuinely event flavor and not parity-bearing,
             move the module to @allowlisted here AND add a justifying entry
             to server/docs/RNG_AUDIT.md.
             """
    end
  end

  test "allowlisted modules still exist (prune stale entries)" do
    for module <- @allowlisted do
      path = Path.expand(module, Path.dirname(__DIR__))

      assert File.exists?(path),
             "Allowlisted RNG module #{module} no longer exists — prune it from " <>
               "@allowlisted and server/docs/RNG_AUDIT.md."
    end
  end

  test "allowlisted modules actually use raw RNG (otherwise promote to @guarded)" do
    # If an allowlisted module has been fully migrated, it no longer needs the
    # exemption — fold it into @guarded so the guard keeps it clean.
    stale =
      Enum.filter(@allowlisted, fn module -> direct_rng_calls(module) == [] end)

    assert stale == [],
           """
           These modules are on the RNG allowlist but no longer contain any
           direct RNG call: #{inspect(stale)}.

           Move them from @allowlisted to @guarded (and update
           server/docs/RNG_AUDIT.md) so the guard protects them going forward.
           """
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp direct_rng_calls(module) do
    path = Path.expand(module, Path.dirname(__DIR__))
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_, found} =
      Macro.prewalk(ast, [], fn
        # :rand.uniform(...) / :rand.uniform_real(...)
        {{:., _, [:rand, fun]}, _, _} = node, acc when fun in [:uniform, :uniform_real] ->
          {node, [":rand.#{fun}" | acc]}

        # Enum.random(...) / Enum.shuffle(...)
        {{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, _} = node, acc
        when fun in [:random, :shuffle] ->
          {node, ["Enum.#{fun}" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end
end
