defmodule Arena.FactionCouncilMessageTest do
  @moduledoc """
  Drift #4 — Council-rank faction messages.

  VB6 reference: old/server/Codigo/Protocol.bas:5177-5209
  (`HandleRoyalArmyMessage` / `HandleChaosLegionMessage`). Both handlers
  accept the broadcast when the user has GM privileges OR
  `.Faccion.Status = e_Facciones.consejo` / `.concilio`.

  Elixir previously gated /RMSG /CMSG on `:dios` GM tier, locking council
  members out. These tests verify parity with the VB6 authorization model.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Chat

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

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
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
      skills: %{},
      spells: [],
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
      saddle_slot: 0
    }

    Map.merge(defaults, overrides)
  end

  defp collect_console_messages(pid, timeout \\ 50) do
    receive do
      {:send_raw, bin} ->
        [bin | collect_console_messages(pid, timeout)]

      # GM faction-message broadcasts now flow through the effects runner,
      # which routes via `AoSession.Egress.enqueue/2` and lands as
      # `{:egress, %Outbound{payload: <<...>>}}` in the test pid mailbox.
      {:egress, %{payload: bin}} ->
        [bin | collect_console_messages(pid, timeout)]
    after
      timeout -> []
    end
  end

  defp contains_faction_broadcast?(bins, label, message) do
    needle = "[#{label}] #{message}"
    Enum.any?(bins, fn bin -> String.contains?(IO.iodata_to_binary(bin), needle) end)
  end

  describe "Royal Council member /RMSG (drift #4)" do
    test "non-GM Royal Council can broadcast to Royal Army members" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "Consejero",
          gm: false,
          faction: :royal_army,
          council: :royal
        })

      recipient_a =
        make_entity(%{
          char_id: :soldier_a,
          name: "SoldierA",
          faction: :royal_army,
          char_index: 2
        })

      recipient_b =
        make_entity(%{
          char_id: :soldier_b,
          name: "SoldierB",
          faction: :royal_army,
          char_index: 3
        })

      # Non-royal recipient must not receive
      outsider =
        make_entity(%{
          char_id: :chaos_member,
          name: "ChaosGuy",
          faction: :chaos_legion,
          char_index: 4
        })

      sender_session = self()
      {:ok, recipient_a_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)
      {:ok, recipient_b_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)
      {:ok, outsider_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)

      sessions = %{
        sender: sender_session,
        soldier_a: recipient_a_pid,
        soldier_b: recipient_b_pid,
        chaos_member: outsider_pid
      }

      state =
        map_state(
          players: %{
            sender: sender,
            soldier_a: recipient_a,
            soldier_b: recipient_b,
            chaos_member: outsider
          },
          sessions: sessions,
          npcs_live: %{},
          occupancy: %{},
          meta: %{rain: false, sin_invi_ocul: false}
        )

      {:ok, new_state, effects} =        Chat.handle_chat(state, :sender, "/RMSG Por el rey!")
      Arena.Map.Effects.run(new_state, effects)

      # The sender's own pid should NOT receive any [Armada Real] broadcast
      # via the sender_session (sender is self()). But the recipient tasks
      # aren't the current process, so we can't easily pull their mailboxes
      # directly. Instead, verify indirectly: sender is part of royal_army,
      # so it SHOULD be included in the broadcast and the test process will
      # receive the message.
      messages = collect_console_messages(self())

      assert contains_faction_broadcast?(messages, "Armada Real", "Por el rey!"),
             "Expected royal army broadcast to include the sender (royal_army faction member), got: #{inspect(messages)}"
    end

    test "Royal Council CANNOT broadcast /CMSG (faction mismatch)" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "RoyalCouncil",
          gm: false,
          faction: :royal_army,
          council: :royal
        })

      chaos_member =
        make_entity(%{
          char_id: :chaos_m,
          name: "ChaosMember",
          faction: :chaos_legion,
          char_index: 2
        })

      sender_session = self()
      {:ok, chaos_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)

      sessions = %{sender: sender_session, chaos_m: chaos_pid}

      state =
        map_state(
          players: %{sender: sender, chaos_m: chaos_member},
          sessions: sessions,
          npcs_live: %{},
          occupancy: %{},
          meta: %{rain: false, sin_invi_ocul: false}
        )

      {:ok, new_state, effects} =        Chat.handle_chat(state, :sender, "/CMSG Glory to chaos!")
      Arena.Map.Effects.run(new_state, effects)

      messages = collect_console_messages(self())

      refute contains_faction_broadcast?(messages, "Legion del Caos", "Glory to chaos!"),
             "Royal Council must not be able to broadcast /CMSG to the Chaos Legion"
    end
  end

  describe "Chaos Council member /CMSG (drift #4)" do
    test "non-GM Chaos Council can broadcast to Chaos Legion members" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "ChaosCouncil",
          gm: false,
          faction: :chaos_legion,
          council: :chaos,
          criminal: true
        })

      chaos_member =
        make_entity(%{
          char_id: :chaos_m,
          name: "ChaosMember",
          faction: :chaos_legion,
          char_index: 2
        })

      royal_member =
        make_entity(%{
          char_id: :royal_m,
          name: "RoyalMember",
          faction: :royal_army,
          char_index: 3
        })

      sender_session = self()
      {:ok, chaos_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)
      {:ok, royal_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)

      sessions = %{
        sender: sender_session,
        chaos_m: chaos_pid,
        royal_m: royal_pid
      }

      state =
        map_state(
          players: %{
            sender: sender,
            chaos_m: chaos_member,
            royal_m: royal_member
          },
          sessions: sessions,
          npcs_live: %{},
          occupancy: %{},
          meta: %{rain: false, sin_invi_ocul: false}
        )

      {:ok, new_state, effects} =        Chat.handle_chat(state, :sender, "/CMSG Por el caos!")
      Arena.Map.Effects.run(new_state, effects)

      messages = collect_console_messages(self())

      assert contains_faction_broadcast?(messages, "Legion del Caos", "Por el caos!"),
             "Expected chaos legion broadcast to include the sender (chaos_legion faction member), got: #{inspect(messages)}"
    end
  end

  describe "Unauthorized broadcasters (drift #4)" do
    test "non-GM non-council player cannot use /RMSG" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "RegularSoldier",
          gm: false,
          faction: :royal_army,
          # not on council
          council: false
        })

      other_royal =
        make_entity(%{
          char_id: :other,
          name: "OtherRoyal",
          faction: :royal_army,
          char_index: 2
        })

      sender_session = self()
      {:ok, other_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)

      sessions = %{sender: sender_session, other: other_pid}

      state =
        map_state(
          players: %{sender: sender, other: other_royal},
          sessions: sessions,
          npcs_live: %{},
          occupancy: %{},
          meta: %{rain: false, sin_invi_ocul: false}
        )

      {:ok, new_state, effects} =        Chat.handle_chat(state, :sender, "/RMSG unauthorised broadcast")
      Arena.Map.Effects.run(new_state, effects)

      messages = collect_console_messages(self())

      refute contains_faction_broadcast?(messages, "Armada Real", "unauthorised broadcast"),
             "Regular (non-GM, non-council) soldier must not be able to broadcast /RMSG"
    end

    test "non-GM non-council player cannot use /CMSG" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "RegularChaos",
          gm: false,
          faction: :chaos_legion,
          council: false
        })

      other_chaos =
        make_entity(%{
          char_id: :other,
          name: "OtherChaos",
          faction: :chaos_legion,
          char_index: 2
        })

      sender_session = self()
      {:ok, other_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)

      sessions = %{sender: sender_session, other: other_pid}

      state =
        map_state(
          players: %{sender: sender, other: other_chaos},
          sessions: sessions,
          npcs_live: %{},
          occupancy: %{},
          meta: %{rain: false, sin_invi_ocul: false}
        )

      {:ok, new_state, effects} =        Chat.handle_chat(state, :sender, "/CMSG unauthorised chaos broadcast")
      Arena.Map.Effects.run(new_state, effects)

      messages = collect_console_messages(self())

      refute contains_faction_broadcast?(messages, "Legion del Caos", "unauthorised chaos broadcast"),
             "Regular (non-GM, non-council) chaos soldier must not be able to broadcast /CMSG"
    end
  end

  describe "GM broadcasters still work (backwards compat)" do
    test "GM without council status can still broadcast /RMSG" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "Dios",
          gm: true,
          gm_level: :dios,
          faction: :royal_army
        })

      recipient =
        make_entity(%{
          char_id: :r,
          name: "Royal",
          faction: :royal_army,
          char_index: 2
        })

      sender_session = self()
      {:ok, r_pid} = Task.start_link(fn -> Process.sleep(:infinity) end)

      sessions = %{sender: sender_session, r: r_pid}

      state =
        map_state(
          players: %{sender: sender, r: recipient},
          sessions: sessions,
          npcs_live: %{},
          occupancy: %{},
          meta: %{rain: false, sin_invi_ocul: false}
        )

      {:ok, new_state, effects} = Chat.handle_chat(state, :sender, "/RMSG gm broadcast")
      Arena.Map.Effects.run(new_state, effects)

      messages = collect_console_messages(self())

      assert contains_faction_broadcast?(messages, "Armada Real", "gm broadcast"),
             "GM (dios tier) must still be able to broadcast /RMSG"
    end
  end
end
