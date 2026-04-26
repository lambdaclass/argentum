defmodule Arena.Map.NpcInteractionDispatcherE2ETest do
  @moduledoc """
  End-to-end tests for the dispatcher's pure-text branches through
  `Arena.Map.MapServer.handle_cast({:double_click, ...}, state)`. Pins the
  slice 5 effects migration of the `Arena.Map.NpcInteraction` dispatcher.

  After slice 5 every pure-text dispatcher branch (out-of-range, priest,
  entrenador, timbero, arena_guard, default fallthrough) emits a
  console envelope through `Arena.Map.Effects.run_handler/2` →
  `Effects.run/2` → `Helpers.send_outbound/3` → `AoSession.Egress.enqueue/2`.
  Tests assert `{:egress, %{payload: <<...>>}}` envelopes arrive at the
  test pid (which acts as the session) and that the legacy
  `{:send_raw, _}` shim no longer fires.

  Adversarial coverage:

    * out-of-range with a dead player (early return, no envelope at all),
    * non-NPC tile occupancy with no ground item or non-forum item,
    * NPC instance present in occupancy but missing from `npcs_live`,
    * NPC in `npcs_live` whose `npc_id` is not registered in GameData.

  Pattern mirrors `npc_interaction_arena_entry_e2e_test.exs` (slice 3).
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  # NPC type constants (kept in sync with Arena.Map.NpcInteraction).
  @npc_type_revividor 1
  @npc_type_entrenador 3
  # VB6 enum: ResucitadorNewbie = 9
  @npc_type_resucitador_newbie 9
  @npc_type_timbero 10
  @npc_type_arena_guard 24
  # Used to exercise the default fallthrough branch — no handler claims it.
  @npc_type_unknown 99

  # Test NPC IDs
  @priest_npc_id 99_810
  @newbie_priest_npc_id 99_811
  @entrenador_npc_id 99_812
  @timbero_npc_id 99_813
  @arena_guard_npc_id 99_814
  @arena_guard_free_npc_id 99_815
  @generic_npc_id 99_816

  @priest_def %{
    id: @priest_npc_id,
    npc_id: @priest_npc_id,
    name: "Sacerdote",
    npc_type: @npc_type_revividor,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @newbie_priest_def %{
    id: @newbie_priest_npc_id,
    npc_id: @newbie_priest_npc_id,
    name: "SacerdoteNewbie",
    npc_type: @npc_type_resucitador_newbie,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @entrenador_def %{
    id: @entrenador_npc_id,
    npc_id: @entrenador_npc_id,
    name: "Entrenador",
    npc_type: @npc_type_entrenador,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @timbero_def %{
    id: @timbero_npc_id,
    npc_id: @timbero_npc_id,
    name: "Apostador",
    npc_type: @npc_type_timbero,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @arena_guard_def %{
    id: @arena_guard_npc_id,
    npc_id: @arena_guard_npc_id,
    name: "ArenaGuard",
    npc_type: @npc_type_arena_guard,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: [],
    arena_price: 100
  }

  @arena_guard_free_def %{
    id: @arena_guard_free_npc_id,
    npc_id: @arena_guard_free_npc_id,
    name: "ArenaGuardFree",
    npc_type: @npc_type_arena_guard,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: [],
    arena_price: 0
  }

  @generic_def %{
    id: @generic_npc_id,
    npc_id: @generic_npc_id,
    name: "Aldeano",
    npc_type: @npc_type_unknown,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  defp make_entity(overrides) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      heading: :south,
      body_id: 1,
      base_body_id: 1,
      head_id: 1,
      hp: 100,
      max_hp: 100,
      mana: 200,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 25,
      xp: 0,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      gold: 5_000,
      inventory: List.duplicate(nil, 24),
      equipment: %{
        weapon: nil,
        armor: nil,
        shield: nil,
        helmet: nil,
        ring: nil,
        municion: nil,
        saddle: nil
      },
      skills: %{magic: 80},
      spells: [1],
      buffs: [],
      min_hit: 0,
      max_hit: 0,
      str_buff: 0,
      agi_buff: 0,
      dead: false,
      poisoned: false,
      criminal: false,
      invisible: false,
      oculto: false,
      oculto_timer: 0,
      no_detectable: false,
      paralyzed: false,
      immobilized: false,
      meditating: false,
      resting: false,
      safe_mode: false,
      navigating: false,
      gm: false,
      faction: :none,
      next_move_at: -1_000_000_000_000,
      next_attack_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      next_item_use_at: -1_000_000_000_000,
      spell_cooldowns: %{},
      char_index: 1,
      map_id: 1,
      npcs_killed: 0,
      deaths: 0,
      penalty: 0,
      skill_points: 0,
      home_city: :ullathorpe,
      faction_kills_royal: 0,
      faction_kills_chaos: 0,
      citizens_killed: 0,
      criminals_killed: 0,
      faction_score: 0,
      faction_rank_armada: 0,
      faction_rank_chaos: 0,
      faction_reenlistadas: 0,
      fishing_points: 0,
      last_step_at: -1_000_000_000_000,
      speed_hack_counter: 0.0,
      speeding: 1.0,
      commerce_npc_id: nil,
      bank_npc_id: nil,
      bank_gold: 0,
      trade_request_target: nil,
      trade_partner_id: nil,
      trade_offer_gold: 0,
      trade_offer_items: [],
      trade_accepted: false,
      pet_ids: [],
      description: "",
      muted_until: 0,
      last_chat_at: -1_000_000_000_000,
      spouse_id: 0,
      marriage_proposal_target: nil,
      in_duel: false,
      duel_opponent_id: nil,
      gamble_wins: 0,
      gamble_losses: 0,
      gamble_plays: 0,
      active_quests: [],
      completed_quests: MapSet.new(),
      quest_npc_id: nil,
      mounted: false,
      saddle_obj_index: 0,
      saddle_slot: 0,
      last_clicked_npc_instance_id: nil,
      last_clicked_npc_type: nil,
      punishments: []
    }

    Map.merge(defaults, overrides)
  end

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:npc, @priest_npc_id}, @priest_def})
    :ets.insert(:arena_game_data, {{:npc, @newbie_priest_npc_id}, @newbie_priest_def})
    :ets.insert(:arena_game_data, {{:npc, @entrenador_npc_id}, @entrenador_def})
    :ets.insert(:arena_game_data, {{:npc, @timbero_npc_id}, @timbero_def})
    :ets.insert(:arena_game_data, {{:npc, @arena_guard_npc_id}, @arena_guard_def})
    :ets.insert(:arena_game_data, {{:npc, @arena_guard_free_npc_id}, @arena_guard_free_def})
    :ets.insert(:arena_game_data, {{:npc, @generic_npc_id}, @generic_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @priest_npc_id})
      :ets.delete(:arena_game_data, {:npc, @newbie_priest_npc_id})
      :ets.delete(:arena_game_data, {:npc, @entrenador_npc_id})
      :ets.delete(:arena_game_data, {:npc, @timbero_npc_id})
      :ets.delete(:arena_game_data, {:npc, @arena_guard_npc_id})
      :ets.delete(:arena_game_data, {:npc, @arena_guard_free_npc_id})
      :ets.delete(:arena_game_data, {:npc, @generic_npc_id})
    end)

    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp npc_at(npc_id, instance_id, x, y) do
    %{npc_id: npc_id, x: x, y: y, instance_id: instance_id}
  end

  # Builds a state with the player at (50, 50), session pointing at the test
  # pid, and (optionally) an NPC instance occupying tile (51, 50) with a
  # matching `npcs_live` entry. Pass `:occupancy` and `:npcs_live` to override
  # the defaults — used by adversarial tests for the missing-instance and
  # missing-game-data branches.
  defp state_with(entity_overrides, opts \\ []) do
    entity = make_entity(entity_overrides)

    occupancy = Keyword.get(opts, :occupancy, %{})
    npcs_live = Keyword.get(opts, :npcs_live, %{})
    ground_items = Keyword.get(opts, :ground_items, %{})

    map_state(
      players: %{player: entity},
      sessions: %{player: self()},
      occupancy: occupancy,
      npcs_live: npcs_live,
      ground_items: ground_items
    )
  end

  defp console_id, do: AoProtocol.PacketIds.Server.console_msg()

  # Helper: assert the next egress envelope is a console_msg whose payload
  # contains `needle`. Returns the matched payload binary.
  defp assert_console(needle) do
    cid = console_id()

    assert_receive {:egress,
                    %{payload: <<^cid::little-signed-integer-16, _::binary>> = payload}}

    assert :binary.match(payload, needle) != :nomatch,
           "expected console payload to contain #{inspect(needle)}, got: #{inspect(payload)}"

    payload
  end

  # ════════════════════════════════════════════════════════════════════════
  # 1. Out-of-range double-click — emits "Estas demasiado lejos."
  # ════════════════════════════════════════════════════════════════════════

  describe "out-of-range double-click" do
    test "entity at (50,50), target at (60,60) → 'Estas demasiado lejos.' envelope" do
      state = state_with(%{x: 50, y: 50})

      assert {:noreply, ^state} =
               MapServer.handle_cast({:double_click, :player, 60, 60}, state)

      assert_console("Estas demasiado lejos.")
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # 2. Priest revividor (alive) — "Puedo curarte" + prontuario
  # ════════════════════════════════════════════════════════════════════════

  describe "priest revividor double-click" do
    test "alive player: 'Puedo curarte' THEN prontuario, in order" do
      state =
        state_with(
          %{x: 50, y: 50, dead: false},
          occupancy: %{{51, 50} => {:npc, :priest_inst}},
          npcs_live: %{priest_inst: npc_at(@priest_npc_id, :priest_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      # First envelope: priest invitation
      assert_console("Puedo curarte")

      # Second envelope: prontuario (default empty → "Sin prontuario.")
      assert_console("Sin prontuario.")

      refute_receive {:send_raw, _}, 50
    end

    test "dead player: 'Puedo resucitarte' THEN prontuario, in order" do
      # `handle_double_click/4` returns early for dead players (no envelope),
      # so the dead-priest copy is unreachable from the cast. We exercise the
      # priest branch by calling `handle_npc_double_click/4` directly with a
      # dead entity — which is exactly what the dispatcher would do if its
      # dead-check were lifted. This pins the dead-branch's effects ordering
      # without requiring a contrived state shape.
      state =
        state_with(
          %{x: 50, y: 50, dead: true},
          npcs_live: %{priest_inst: npc_at(@priest_npc_id, :priest_inst, 51, 50)}
        )

      entity = state.players[:player]

      assert {:noreply, _new_state} =
               Arena.Map.NpcInteraction.handle_npc_double_click(
                 state,
                 :player,
                 entity,
                 :priest_inst
               )

      assert_console("Puedo resucitarte")
      assert_console("Sin prontuario.")

      refute_receive {:send_raw, _}, 50
    end

    test "resucitador_newbie (alive, low level): 'Puedo curarte' THEN prontuario" do
      state =
        state_with(
          %{x: 50, y: 50, dead: false, level: 10},
          occupancy: %{{51, 50} => {:npc, :priest_inst}},
          npcs_live: %{priest_inst: npc_at(@newbie_priest_npc_id, :priest_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert_console("Puedo curarte")
      assert_console("Sin prontuario.")

      refute_receive {:send_raw, _}, 50
    end

    test "effect ordering: priest message strictly precedes prontuario envelope" do
      state =
        state_with(
          %{x: 50, y: 50, dead: false},
          occupancy: %{{51, 50} => {:npc, :priest_inst}},
          npcs_live: %{priest_inst: npc_at(@priest_npc_id, :priest_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      cid = console_id()

      # Pin order strictly: first envelope must contain "Puedo curarte",
      # second must contain "Sin prontuario." (or the formatted record).
      assert_receive {:egress,
                      %{payload: <<^cid::little-signed-integer-16, _::binary>> = first}}

      assert :binary.match(first, "Puedo curarte") != :nomatch,
             "first envelope must be priest invitation"

      assert_receive {:egress,
                      %{payload: <<^cid::little-signed-integer-16, _::binary>> = second}}

      assert :binary.match(second, "Sin prontuario.") != :nomatch,
             "second envelope must be prontuario"

      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # 3. Entrenador double-click — "Puedo entrenarte."
  # ════════════════════════════════════════════════════════════════════════

  describe "entrenador double-click" do
    test "emits 'Puedo entrenarte.' envelope" do
      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :trainer_inst}},
          npcs_live: %{trainer_inst: npc_at(@entrenador_npc_id, :trainer_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert_console("Puedo entrenarte")
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # 4. Timbero double-click — "Haz tu apuesta..."
  # ════════════════════════════════════════════════════════════════════════

  describe "timbero double-click" do
    test "emits APOSTAR instructions envelope" do
      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :timbero_inst}},
          npcs_live: %{timbero_inst: npc_at(@timbero_npc_id, :timbero_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert_console("/APOSTAR")
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # 5. Arena guard double-click — paid + free variants
  # ════════════════════════════════════════════════════════════════════════

  describe "arena_guard double-click" do
    test "with arena_price > 0: 'La entrada a la arena cuesta N monedas...'" do
      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :guard_inst}},
          npcs_live: %{guard_inst: npc_at(@arena_guard_npc_id, :guard_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert_console("La entrada a la arena cuesta 100 monedas")
      refute_receive {:send_raw, _}, 50
    end

    test "with arena_price == 0: 'Bienvenido a la arena.'" do
      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :guard_inst}},
          npcs_live: %{guard_inst: npc_at(@arena_guard_free_npc_id, :guard_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert_console("Bienvenido a la arena.")
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # 6. Default branch ("Ves a #{name}.") — unknown NPC type fallthrough
  # ════════════════════════════════════════════════════════════════════════

  describe "default branch (unknown npc_type)" do
    test "emits 'Ves a #{"Aldeano"}.' envelope" do
      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :npc_inst}},
          npcs_live: %{npc_inst: npc_at(@generic_npc_id, :npc_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert_console("Ves a Aldeano.")
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Adversarial coverage
  # ════════════════════════════════════════════════════════════════════════

  describe "adversarial: dispatcher silently no-ops where it should" do
    test "out-of-range AND dead player: dead check runs first → no envelopes" do
      state = state_with(%{x: 50, y: 50, dead: true})

      assert {:noreply, ^state} =
               MapServer.handle_cast({:double_click, :player, 60, 60}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "ground item with no forum_id (item not in GameData): silent no-op" do
      # ground_items[{51, 50}] points at an item_id that is not registered in
      # GameData, so `GameData.get_item/1` returns nil → handler falls through
      # to `{:noreply, state}` with no envelope.
      state =
        state_with(
          %{x: 50, y: 50},
          ground_items: %{{51, 50} => %{item_id: 999_999}}
        )

      assert {:noreply, ^state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "occupancy points at NPC instance not present in npcs_live: silent no-op" do
      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :ghost_inst}},
          npcs_live: %{}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "NPC in npcs_live whose npc_id is unregistered in GameData: silent no-op" do
      # NPC instance present, but `GameData.get_npc/1` returns nil for an
      # unregistered ID → handler bails with `{:noreply, state}` before
      # reaching any branch. We use an ID outside the shipped npcs.dat range
      # AND outside our test fixtures (and we explicitly delete it in case a
      # prior test left it behind).
      ghost_id = 9_999_999
      :ets.delete(:arena_game_data, {:npc, ghost_id})

      assert GameData.get_npc(ghost_id) == nil,
             "ghost npc_id must NOT be registered for this test to be meaningful"

      state =
        state_with(
          %{x: 50, y: 50},
          occupancy: %{{51, 50} => {:npc, :ghost_inst}},
          npcs_live: %{ghost_inst: npc_at(ghost_id, :ghost_inst, 51, 50)}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
