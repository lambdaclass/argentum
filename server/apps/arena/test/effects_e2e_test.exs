defmodule Arena.Map.EffectsE2ETest do
  @moduledoc """
  End-to-end tests for the effects pipeline through `Arena.Map.MapServer`'s
  `handle_cast/2` clauses for `:rest`, `:meditate`, and `:resucitate`.

  ## Why no real GenServer

  Spinning a real `MapServer` requires the `Registry`, `TileGrid` NIF data,
  full map metadata loaded from disk, etc. — overkill for what we're trying
  to pin: that the cast → `Effects.run_handler/2` → `Effects.run/2` →
  `Helpers.send_outbound/3` → `AoSession.Egress.enqueue/2` → mailbox path is
  wired correctly in `MapServer`'s cast clauses (not just the standalone
  `Effects` runner).

  We invoke `MapServer.handle_cast/2` directly as a function call, with a
  hand-built `%Arena.Map.State{}` from `Arena.Test.MapStateFactory`. This is
  the same pattern used by `chat_color_handler_test.exs` and
  `gm_panel_handler_test.exs` for the same reason.

  ## What this guards

  * The cast bodies stay one-liners delegating to `Effects.run_handler/2`.
    If anyone refactors them back to direct sends, the legacy `{:send_raw, _}`
    shim would reappear in the mailbox and the `refute_receive {:send_raw, _}`
    assertions would fail.
  * The session pid receives `{:egress, %Outbound{}}` envelopes (matched as
    a map to avoid struct literals in arena, per dependency boundary rules).
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.NpcDef

  import Arena.Test.MapStateFactory

  @npc_type_revividor 1
  @fogata_obj_index 21

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
      hp: 50,
      max_hp: 100,
      mana: 50,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 25,
      xp: 0,
      class: :mage,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      gold: 1000,
      inventory: List.duplicate(nil, 24),
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
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
      blind: false,
      dumb: false,
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
      saddle_slot: 0
    }

    Map.merge(defaults, overrides)
  end

  defp revividor_def do
    %NpcDef{
      id: 500,
      npc_type: @npc_type_revividor,
      name: "Sacerdote",
      faccion: 0,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  setup do
    unless Process.whereis(Arena.Data.GameData) do
      {:ok, _} = Arena.Data.GameData.start_link([])
    end

    :ets.insert(:arena_game_data, {{:npc, 500}, revividor_def()})

    drain()
    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  describe "MapServer.handle_cast({:rest, char_id}) — full effects pipeline" do
    test "rest with no campfire enqueues a critical 'No hay fogata cerca.' envelope" do
      entity = make_entity(%{hp: 50, max_hp: 100, resting: false})

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          ground_items: %{}
        )

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:rest, :player}, state)

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{
                        class: :critical,
                        payload: <<^console_id::little-signed-integer-16, _::binary>>
                      }}

      # Pin: the legacy {:send_raw, _} shim must NOT appear in this path.
      refute_receive {:send_raw, _}, 50
    end

    test "successful rest enqueues console + rest_ok via Egress, never legacy shim" do
      entity = make_entity(%{hp: 50, max_hp: 100, resting: false})
      fogata_item = %{item_id: @fogata_obj_index, amount: 1, elemental_tags: 0}

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          ground_items: %{{50, 51} => fogata_item}
        )

      assert {:noreply, new_state} =
               MapServer.handle_cast({:rest, :player}, state)

      assert new_state.players[:player].resting

      console_id = AoProtocol.PacketIds.Server.console_msg()
      rest_ok_id = AoProtocol.PacketIds.Server.rest_ok()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{payload: <<^rest_ok_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end
  end

  describe "MapServer.handle_cast({:meditate, char_id}) — full effects pipeline" do
    test "starting meditate broadcasts a :lossy create_fx to the peer's mailbox" do
      meditator = make_entity(%{class: :mage, mana: 50, max_mana: 200, x: 50, y: 50})

      origin = self()

      peer_pid =
        spawn_link(fn ->
          loop = fn loop ->
            receive do
              {:egress, env} ->
                Kernel.send(origin, {:peer_egress, env})
                loop.(loop)

              other ->
                Kernel.send(origin, {:peer_other, other})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      peer_entity =
        make_entity(%{char_id: :peer, char_index: 2, x: 51, y: 50, class: :warrior})

      state =
        map_state(
          players: %{player: meditator, peer: peer_entity},
          sessions: %{player: origin, peer: peer_pid},
          visibility_mode: :global
        )

      assert {:noreply, _} = MapServer.handle_cast({:meditate, :player}, state)

      fx_id = AoProtocol.PacketIds.Server.create_fx()

      # Self gets the console + the FX broadcast (broadcast_visible_all includes origin).
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{class: :critical, payload: <<^console_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{class: :lossy, payload: <<^fx_id::little-signed-integer-16, _::binary>>}}

      # Peer gets the FX broadcast as :lossy.
      assert_receive {:peer_egress,
                      %{class: :lossy, payload: <<^fx_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
      refute_receive {:peer_other, _}, 50
    end
  end

  describe "MapServer.handle_cast({:resucitate, char_id}) — full effects pipeline" do
    test "dead player with selected Revividor: post-state has dead: false and all envelopes arrive" do
      revividor_npc = %{npc_id: 500, x: 51, y: 50, instance_id: :rev1}

      entity =
        make_entity(%{
          dead: true,
          hp: 0,
          max_hp: 100,
          mana: 150,
          max_mana: 200,
          x: 50,
          y: 50,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        })

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{rev1: revividor_npc},
          visibility_mode: :global
        )

      assert {:noreply, new_state} =
               MapServer.handle_cast({:resucitate, :player}, state)

      revived = new_state.players[:player]
      refute revived.dead, "post-state must mark the player as alive"
      assert revived.hp == revived.max_hp

      hp_id = AoProtocol.PacketIds.Server.update_hp()
      mana_id = AoProtocol.PacketIds.Server.update_mana()
      console_id = AoProtocol.PacketIds.Server.console_msg()
      cc_id = AoProtocol.PacketIds.Server.character_change()
      fx_id = AoProtocol.PacketIds.Server.create_fx()

      assert_receive {:egress,
                      %{class: :coalesce, payload: <<^hp_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{class: :coalesce, payload: <<^mana_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{class: :critical, payload: <<^console_id::little-signed-integer-16, _::binary>>}}

      # character_change broadcast (critical) — origin is in :global visibility.
      assert_receive {:egress,
                      %{class: :critical, payload: <<^cc_id::little-signed-integer-16, _::binary>>}}

      # create_fx broadcast_visible_all (lossy) — origin included.
      assert_receive {:egress,
                      %{class: :lossy, payload: <<^fx_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end
  end
end
