defmodule Arena.Map.NpcInteractionInformationE2ETest do
  @moduledoc """
  End-to-end tests for the `{:information, char_id}` cast through
  `Arena.Map.MapServer.handle_cast/2`. Pins the slice 1 effects migration of
  `Arena.Map.NpcInteraction.handle_information/2`.

  The handler now returns `{:ok, state, effects}` and the cast routes through
  `Arena.Map.Effects.run_handler/2` → `Effects.run/2` → `Helpers.send_outbound/3`
  → `AoSession.Egress.enqueue/2` so the legacy `{:send_raw, _}` shim must NOT
  appear on the receiving session pid's mailbox. Instead, an
  `{:egress, %{payload: <<...>>}}` envelope is delivered.

  Pattern mirrors `effects_e2e_test.exs` (rest/meditate/resucitate).
  """

  use ExUnit.Case, async: false

  alias Arena.Map.{MapServer, NpcInteraction}
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  @npc_type_enlistador 5

  @enlistador_royal_def %{
    id: 88_901,
    npc_id: 88_901,
    name: "Enlistador Real",
    npc_type: @npc_type_enlistador,
    faccion: 3,
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
      gold: 1000,
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
      faction: :royal_army,
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
      saddle_slot: 0
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
    :ets.insert(:arena_game_data, {{:npc, 88_901}, @enlistador_royal_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, 88_901})
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

  describe "NpcInteraction.handle_information/2 return shape" do
    test "returns {:ok, state, effects} (not {:noreply, _})" do
      entity = make_entity(%{faction: :royal_army})
      enlistador = %{npc_id: 88_901, x: 51, y: 50, hp: 100}

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{enl_inst: enlistador}
        )

      result = NpcInteraction.handle_information(state, :player)

      assert {:ok, ^state, [_ | _]} = result,
             "handle_information must return the migrated {:ok, state, effects} tuple"

      {:ok, _state, effects} = result

      # Each effect must be one of the documented Effects constructors. For the
      # information flow we only emit unicast :send effects.
      assert Enum.all?(effects, fn
               {:send, :player, %{payload: payload}} when is_binary(payload) -> true
               _ -> false
             end),
             "all effects must be {:send, char_id, %Outbound{}} envelopes; got #{inspect(effects)}"
    end
  end

  describe "MapServer.handle_cast({:information, char_id}) — full effects pipeline" do
    test "near royal enlistador: session receives an {:egress, _} envelope, never {:send_raw, _}" do
      entity = make_entity(%{faction: :royal_army})
      enlistador = %{npc_id: 88_901, x: 51, y: 50, hp: 100}

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{enl_inst: enlistador}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:information, :player}, state)

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{
                        class: :critical,
                        payload: <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      # Sanity check: the encoded console_msg payload must contain the VB6
      # royal-army duty message verbatim.
      assert :binary.match(payload, "criminales") != :nomatch

      # Pin: the legacy {:send_raw, _} shim must NOT appear in this path.
      refute_receive {:send_raw, _}, 50
    end

    test "dead player: session receives 'Estas muerto!' via Egress, never {:send_raw, _}" do
      entity = make_entity(%{dead: true, faction: :royal_army})
      enlistador = %{npc_id: 88_901, x: 51, y: 50, hp: 100}

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{enl_inst: enlistador}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:information, :player}, state)

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "muerto") != :nomatch

      refute_receive {:send_raw, _}, 50
    end

    test "no enlistador nearby: no envelope is emitted at all" do
      entity = make_entity(%{faction: :royal_army})

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:information, :player}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
