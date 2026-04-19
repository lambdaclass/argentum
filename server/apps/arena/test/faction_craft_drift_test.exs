defmodule Arena.FactionCraftDriftTest do
  @moduledoc """
  Regression tests for protocol/VB6 drifts:

  Drift #13 — Faction display name inconsistency.
    The canonical name for the Chaos faction is "Legion del Caos" (used in
    faction.ex, session_logic.ex, helpers.ex).  Two GM helper functions
    (gm_faction_message in Events and gm_faction_kick in Moderation) use
    "Legion Oscura" instead — a guild-alignment label, not the faction name.

  Drift #15 — CraftCarpenter amount field silently dropped.
    The wire decoder extracts {item, amount} but the session_logic handler
    only pattern-matches %{item: item}, discarding amount.  The craft
    system should honour amount >= 1 and repeat the craft that many times.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Arena.Test.MapStateFactory

  alias Arena.Map.Gm.{Events, Moderation}
  alias Arena.Map.Crafting
  alias AoEntities.PlayerEntity
  alias Arena.Data.CraftingRecipes

  # ── helpers ──

  defp make_entity(overrides) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50, y: 50,
      heading: :south,
      body_id: 1, base_body_id: 1, head_id: 1,
      hp: 100, max_hp: 100,
      mana: 200, max_mana: 200,
      stamina: 100, max_stamina: 100,
      hunger: 100, thirst: 100,
      level: 25, xp: 0,
      class: :warrior, race: :human, gender: :male,
      str: 18, agi: 18, int: 18, con: 18, cha: 18,
      gold: 0,
      inventory: List.duplicate(nil, 24),
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
      skills: %{magic: 80},
      spells: [1],
      buffs: [],
      min_hit: 0, max_hit: 0,
      str_buff: 0, agi_buff: 0,
      dead: false, poisoned: false, criminal: false,
      invisible: false, oculto: false, oculto_timer: 0,
      no_detectable: false, paralyzed: false, immobilized: false,
      meditating: false, resting: false, safe_mode: false, navigating: false,
      gm: false,
      faction: :none,
      next_move_at: -1_000_000_000_000,
      next_attack_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      next_item_use_at: -1_000_000_000_000,
      spell_cooldowns: %{},
      char_index: 1, map_id: 1,
      npcs_killed: 0, deaths: 0, penalty: 0, skill_points: 0,
      home_city: :ullathorpe,
      faction_kills_royal: 0, faction_kills_chaos: 0,
      citizens_killed: 0, criminals_killed: 0,
      faction_score: 0, faction_rank_armada: 0, faction_rank_chaos: 0,
      faction_reenlistadas: 0, fishing_points: 0,
      last_step_at: -1_000_000_000_000,
      speed_hack_counter: 0.0, speeding: 1.0,
      commerce_npc_id: nil, bank_npc_id: nil, bank_gold: 0,
      trade_request_target: nil, trade_partner_id: nil,
      trade_offer_gold: 0, trade_offer_items: [],
      trade_accepted: false, pet_ids: [],
      description: "", muted_until: 0,
      last_chat_at: -1_000_000_000_000,
      spouse_id: 0, marriage_proposal_target: nil,
      in_duel: false, duel_opponent_id: nil,
      gamble_wins: 0, gamble_losses: 0, gamble_plays: 0,
      active_quests: [], completed_quests: MapSet.new(),
      quest_npc_id: nil, mounted: false,
      saddle_obj_index: 0, saddle_slot: 0
    }
    Map.merge(defaults, overrides)
  end

  defp make_map_state(players, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{})
    map_state(
      players: players,
      sessions: sessions,
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, snow: false, sin_invi_ocul: false}
    )
  end

  defp make_craft_state(players, opts \\ []) do
    trigger_map = Keyword.get(opts, :trigger_map, %{})
    npcs_live = Keyword.get(opts, :npcs_live, %{})

    map_state(
      players: players,
      npcs_live: npcs_live,
      meta: %{safe_zone: false, trigger_map: trigger_map}
    )
  end

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift #13 — Faction display name consistency
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift #13: gm_faction_message uses canonical faction name" do
    test "chaos legion message contains 'Legion del Caos', not 'Legion Oscura'" do
      gm = make_entity(%{char_id: :gm, gm: true, name: "GM_Admin", faction: :none})
      soldier = make_entity(%{char_id: :soldier, faction: :chaos_legion, name: "ChaosGuy", char_index: 2})
      sessions = %{gm: self(), soldier: self()}
      state = make_map_state(%{gm: gm, soldier: soldier}, sessions: sessions)

      log = capture_log(fn ->
        Events.gm_faction_message(state, :gm, :chaos_legion, "Atacar!")
      end)

      # The broadcast should say [Legion del Caos], matching the canonical name
      assert_receive {:send_raw, raw}
      msg = :erlang.iolist_to_binary(raw)
      assert msg =~ "Legion del Caos"
      refute msg =~ "Legion Oscura"

      # The audit log should also use the canonical name
      assert log =~ "Legion del Caos"
    end

    test "royal army message contains 'Armada Real'" do
      gm = make_entity(%{char_id: :gm, gm: true, name: "GM_Admin", faction: :none})
      soldier = make_entity(%{char_id: :soldier, faction: :royal_army, name: "RoyalGuy", char_index: 2})
      sessions = %{gm: self(), soldier: self()}
      state = make_map_state(%{gm: gm, soldier: soldier}, sessions: sessions)

      log = capture_log(fn ->
        Events.gm_faction_message(state, :gm, :royal_army, "Defend!")
      end)

      assert_receive {:send_raw, raw}
      msg = :erlang.iolist_to_binary(raw)
      assert msg =~ "Armada Real"

      assert log =~ "Armada Real"
    end
  end

  describe "Drift #13: gm_faction_kick uses canonical faction name" do
    test "kicking from chaos legion logs 'Legion del Caos', not 'Legion Oscura'" do
      gm = make_entity(%{char_id: 1, gm: true, name: "GM_Admin"})
      target = make_entity(%{char_id: 2, name: "ChaosGuy", char_index: 2, faction: :chaos_legion})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_faction_kick(state, 1, "ChaosGuy", :chaos_legion)
      end)

      assert log =~ "Legion del Caos"
      refute log =~ "Legion Oscura"
    end

    test "kicking from royal army logs 'Armada Real'" do
      gm = make_entity(%{char_id: 1, gm: true, name: "GM_Admin"})
      target = make_entity(%{char_id: 2, name: "RoyalGuy", char_index: 2, faction: :royal_army})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_faction_kick(state, 1, "RoyalGuy", :royal_army)
      end)

      assert log =~ "Armada Real"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift #15 — CraftCarpenter amount field
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift #15: handle_craft_item honours amount for carpentry" do
    test "crafting with amount=3 produces 3 items and consumes 3x ingredients" do
      # Use Arco Simple (result_id 479): needs 200 wood (item 58), min_skill 10
      recipe = CraftingRecipes.find_recipe_by_item(:carpentry, 479)
      assert recipe != nil, "Arco Simple recipe must exist"

      # Give enough wood for 3 crafts: 3 * 200 = 600
      entity = %PlayerEntity{
        char_id: 1, dead: false, stamina: 300, max_stamina: 300,
        class: :worker, race: :human, gender: :male,
        equipment: %{weapon: 198},
        skills: %{carpentry: 50},
        inventory: [%{item_id: 58, amount: 700, equipped: false} | List.duplicate(nil, 23)]
      }
      state = make_craft_state(%{1 => entity})

      {:noreply, new_state} = Crafting.handle_craft_item(state, 1, :carpentry, 479, 3)

      updated = new_state.players[1]

      # Should have consumed 600 wood (700 - 600 = 100 remaining)
      wood_count = updated.inventory
        |> Enum.filter(& &1)
        |> Enum.filter(&(&1.item_id == 58))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      bow_count = updated.inventory
        |> Enum.filter(& &1)
        |> Enum.filter(&(&1.item_id == 479))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      assert wood_count == 100, "Expected 100 wood remaining, got #{wood_count}"
      assert bow_count == 3, "Expected 3 bows crafted, got #{bow_count}"
    end

    test "crafting with amount=1 behaves same as old 4-arity call" do
      entity = %PlayerEntity{
        char_id: 1, dead: false, stamina: 300, max_stamina: 300,
        class: :worker, race: :human, gender: :male,
        equipment: %{weapon: 198},
        skills: %{carpentry: 50},
        inventory: [%{item_id: 58, amount: 700, equipped: false} | List.duplicate(nil, 23)]
      }
      state = make_craft_state(%{1 => entity})

      {:noreply, new_state} = Crafting.handle_craft_item(state, 1, :carpentry, 479, 1)

      updated = new_state.players[1]
      wood_count = updated.inventory
        |> Enum.filter(& &1)
        |> Enum.filter(&(&1.item_id == 58))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      bow_count = updated.inventory
        |> Enum.filter(& &1)
        |> Enum.filter(&(&1.item_id == 479))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      assert wood_count == 500
      assert bow_count == 1
    end

    test "4-arity call defaults to amount=1 (backwards compatibility)" do
      entity = %PlayerEntity{
        char_id: 1, dead: false, stamina: 300, max_stamina: 300,
        class: :worker, race: :human, gender: :male,
        equipment: %{weapon: 198},
        skills: %{carpentry: 50},
        inventory: [%{item_id: 58, amount: 700, equipped: false} | List.duplicate(nil, 23)]
      }
      state = make_craft_state(%{1 => entity})

      {:noreply, new_state} = Crafting.handle_craft_item(state, 1, :carpentry, 479)

      updated = new_state.players[1]
      bow_count = updated.inventory
        |> Enum.filter(& &1)
        |> Enum.filter(&(&1.item_id == 479))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      assert bow_count == 1
    end
  end
end
