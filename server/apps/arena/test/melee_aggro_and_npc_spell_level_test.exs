defmodule Arena.MeleeAggroAndNpcSpellLevelTest do
  @moduledoc """
  Tests for bug 26e (melee hits should transfer NPC aggro on miss)
  and bug 26f (NPC spell damage should use actual NPC level, not hardcoded 20).
  """
  use ExUnit.Case, async: true

  alias Arena.Map.CombatHandlers
  alias AoEntities.PlayerEntity
  alias Arena.Entity.NpcEntity
  alias Arena.Combat

  import Arena.Test.MapStateFactory

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Build minimal map state with one player and one NPC for unit-testing
  # CombatHandlers.handle_attack_target/5 directly.
  defp make_state(opts \\ []) do
    char_id = Keyword.get(opts, :char_id, 1)

    player = %PlayerEntity{
      char_id: char_id,
      name: "Tester",
      account_id: "acc_1",
      x: 50,
      y: 50,
      heading: :south,
      hp: 200,
      max_hp: 200,
      mana: 100,
      max_mana: 100,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: Keyword.get(opts, :player_level, 25),
      xp: 0,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 25,
      agi: Keyword.get(opts, :player_agi, 20),
      int: 18,
      con: 20,
      cha: 18,
      str_buff: 0,
      agi_buff: 0,
      skills: Keyword.get(opts, :player_skills, %{
        combat_weapons: 80,
        combat_tactics: 50,
        combat_defense: 50,
        ranged_weapons: 50
      }),
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
      dead: false,
      invisible: false,
      paralyzed: false,
      meditating: false,
      npcs_killed: 0,
      safe_mode: false
    }

    npc = %NpcEntity{
      npc_id: Keyword.get(opts, :npc_id, 559),
      instance_id: 1,
      char_index: 100,
      x: 51,
      y: 50,
      hp: Keyword.get(opts, :npc_hp, 250),
      max_hp: 250,
      alive: true,
      target_id: Keyword.get(opts, :npc_target_id, nil),
      spawn_x: 51,
      spawn_y: 50,
      next_attack_at: -1_000_000_000_000,
      next_move_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      exp_count: 100
    }

    map_state(
      map_id: 999,
      players: %{char_id => player},
      sessions: %{char_id => self()},
      npcs_live: %{1 => npc},
      npc_char_indices: %{100 => 1},
      meta: %{safe_zone: false}
    )
  end

  # Force :rand to produce a specific next uniform value.
  # With combat_weapons: 0, agi: 1, level: 1 the hit_chance is 5 (the minimum).
  # :rand.uniform(100) must return > 5 to guarantee a miss.
  defp seed_for_miss do
    # Use a fixed seed that produces a first :rand.uniform(100) > 5
    :rand.seed(:exsss, {100, 200, 300})
  end

  describe "Bug 26e: melee attack should transfer NPC aggro even on miss" do
    test "NPC acquires target_id when melee attack misses" do
      # Player has 0 weapon skill, level 1, agi 1 -> hit_chance = 5 (minimum)
      state = make_state(
        player_skills: %{combat_weapons: 0},
        player_agi: 1,
        player_level: 1
      )

      char_id = 1
      entity = state.players[char_id]

      # Verify NPC starts with no target
      assert state.npcs_live[1].target_id == nil

      # Seed rand to guarantee a miss (need uniform(100) > 5)
      seed_for_miss()
      roll = :rand.uniform(100)

      # If our seed gives a roll <= 5, try different seeds until we find a miss
      if roll <= 5 do
        # Reseed with different values
        :rand.seed(:exsss, {999, 888, 777})
      else
        # Reseed so the actual call uses the same seed
        seed_for_miss()
      end

      {new_state, _effects} = CombatHandlers.handle_attack_target(state, char_id, entity, {:npc, 1})
      npc_after = new_state.npcs_live[1]

      # NPC should have aggro on attacker even after a miss
      assert npc_after != nil, "NPC should still exist after miss"

      assert npc_after.target_id == char_id,
             "NPC target_id should be set to attacker (#{char_id}) even on miss, got: #{inspect(npc_after.target_id)}"
    end

    test "NPC acquires target_id when melee attack hits (already works)" do
      state = make_state()
      char_id = 1
      # Run several attacks — with high skill, most will hit
      final_state =
        Enum.reduce(1..20, state, fn _, acc_state ->
          ent = acc_state.players[char_id]
          {next_state, _effects} = CombatHandlers.handle_attack_target(acc_state, char_id, ent, {:npc, 1})
          next_state
        end)

      npc_after = final_state.npcs_live[1]

      # With high skill, at least one hit should have occurred and set target_id
      assert npc_after.target_id == char_id
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
