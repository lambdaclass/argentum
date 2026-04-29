defmodule Arena.MeleeAggroAndNpcSpellLevelTest do
  @moduledoc """
  Bug 26e (NPC aggro on melee miss) + bug 26f (NPC spell damage uses
  actual NPC level). Migrated to `Arena.Test.Scenario` in slice 4 of
  the harness rollout.

  Originally hand-rolled a `make_state` with one player + one NPC and
  drove `CombatHandlers.handle_attack_target/4` directly with seeded
  `:rand`. The harness now drives the same flow via:

      Scenario.new()
      |> with_player(:atk, …)
      |> with_npc(1, npc_id: 559, x: 51, y: 50)
      |> set_seed(101)             # constant > hit_chance forces miss
      |> run_effects(fn s -> CombatHandlers.handle_attack_target(s, :atk, entity, {:npc, 1}) end)

  The aggro-on-miss test now uses `Scenario.set_seed/2` (forcing a miss
  via `Arena.Rng.uniform/1` returning a constant > 5) instead of the
  guess-and-check `:rand.seed` dance.

  The Bug 26f tests (`Combat.spell_damage` statistical comparison and
  the source-text grep on `npc_def_level`) don't touch handlers, so
  they're left as plain ExUnit asserts — the harness wouldn't add
  anything.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.CombatHandlers
  alias Arena.Combat

  import Arena.Test.Scenario

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "Bug 26e: melee attack should transfer NPC aggro even on miss" do
    test "NPC acquires target_id when melee attack misses" do
      # Player has 0 weapon skill, level 1, agi 1 -> hit_chance = 5 (the floor).
      # `set_seed(101)` returns 101 for every `Arena.Rng.uniform/1` call, so
      # `Rng.uniform(100) <= 5` is false → the swing always misses.
      s =
        new()
        |> with_player(:atk,
          x: 50, y: 50, heading: :south,
          str: 25, agi: 1, level: 1,
          hp: 200, max_hp: 200, mana: 100, max_mana: 100,
          stamina: 100, max_stamina: 100,
          class: :warrior,
          skills: %{combat_weapons: 0}
        )
        |> with_npc(1,
          npc_id: 559, char_index: 100, x: 51, y: 50,
          hp: 250, max_hp: 250, exp_count: 100
        )
        |> set_seed(101)

      # Verify NPC starts with no target.
      assert state(s).npcs_live[1].target_id == nil

      attacker = entity(s, :atk)

      s =
        run_effects(s, fn st ->
          CombatHandlers.handle_attack_target(st, :atk, attacker, {:npc, 1})
        end)

      npc_after = state(s).npcs_live[1]

      assert npc_after != nil, "NPC should still exist after miss"

      assert npc_after.target_id == :atk,
             "NPC target_id should be set to attacker (:atk) even on miss, got: #{inspect(npc_after.target_id)}"
    end

    test "NPC acquires target_id when melee attack hits (already works)" do
      # High weapon skill should hit at least once across 20 swings.
      s =
        new()
        |> with_player(:atk,
          x: 50, y: 50, heading: :south,
          str: 25, agi: 20, level: 25,
          hp: 200, max_hp: 200, mana: 100, max_mana: 100,
          stamina: 100, max_stamina: 100,
          class: :warrior,
          skills: %{
            combat_weapons: 80,
            combat_tactics: 50,
            combat_defense: 50,
            ranged_weapons: 50
          }
        )
        |> with_npc(1,
          npc_id: 559, char_index: 100, x: 51, y: 50,
          hp: 250, max_hp: 250, exp_count: 100
        )

      # Force every roll to land — `set_seed(1)` makes Rng.uniform(100) == 1
      # which is always <= the hit chance.
      s = set_seed(s, 1)

      s =
        Enum.reduce(1..20, s, fn _i, acc ->
          attacker = entity(acc, :atk)

          run_effects(acc, fn st ->
            CombatHandlers.handle_attack_target(st, :atk, attacker, {:npc, 1})
          end)
        end)

      npc_after = state(s).npcs_live[1]

      # With high skill + forced-hit seed, target_id is set on the first
      # hit and stays set for the rest of the swings (or the NPC dies and
      # is removed; either way prior swings established aggro).
      if npc_after do
        assert npc_after.target_id == :atk
      else
        # NPC was killed mid-loop — that itself proves at least one hit
        # landed, which is exactly what the original test covered.
        :ok
      end
    end
  end

  describe "Bug 26f: NPC spell damage uses actual NPC level" do
    test "spell_damage with higher NPC level deals more damage" do
      # Combat.spell_damage uses caster_level for scaling:
      #   damage = base + floor(base * 0.03 * caster_level)
      # With level 35 vs level 1, the level 35 version should consistently deal more.
      results_high =
        for _ <- 1..200 do
          Combat.spell_damage(50, 50, 35, false)
        end

      results_low =
        for _ <- 1..200 do
          Combat.spell_damage(50, 50, 1, false)
        end

      avg_high = Enum.sum(results_high) / length(results_high)
      avg_low = Enum.sum(results_low) / length(results_low)

      assert avg_high > avg_low,
             "Spell damage with level 35 (avg #{avg_high}) should exceed level 1 (avg #{avg_low})"
    end

    test "npc_def_level in NpcAi should use actual NPC definition level, not hardcoded 20" do
      # Verify the source code no longer contains the hardcoded pattern.
      # This is a code-level assertion that the fix was applied.
      source_path =
        Path.expand("../lib/arena/npc_ai.ex", __DIR__)

      {:ok, source} = File.read(source_path)

      refute source =~ ~r/defp npc_def_level\(_[^)]*\), do: 20/,
             "npc_def_level should not return a hardcoded 20; it should use the actual NPC definition level"
    end
  end
end
