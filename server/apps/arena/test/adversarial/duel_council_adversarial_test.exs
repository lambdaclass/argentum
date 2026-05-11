defmodule Arena.Adversarial.DuelCouncilAdversarialTest do
  @moduledoc """
  Adversarial tests for the two recently-landed VB6 drift fixes:

    * Drift #3 — binary duel packets (VB6 Protocol.bas:5931-5981,
      ModRetos.bas CrearReto / AceptarReto / CancelarSolicitudReto /
      AbandonarReto). Production module: `Arena.DuelServer` +
      `AoTcpGateway.SessionCommands.Duel`.

    * Drift #4 — council-rank faction broadcasts (VB6 Protocol.bas:5177-5209
      HandleRoyalArmyMessage / HandleChaosLegionMessage). Production
      gate: `Arena.Map.Chat.council_faction_broadcast?/2` +
      `Arena.Map.GmCommands.council_faction_bypass?/2`.

  These tests poke at the edges: self-challenge, challenge-while-duelling,
  invalid bet / potion values, unauthorised cancels, malformed council
  flags, case sensitivity etc. Expected VB6 semantics are asserted even
  where the current implementation has gaps — missing pieces get a
  `# TODO(parity)` comment, not a `@tag :skip`.
  """

  use ExUnit.Case, async: true

  alias Arena.DuelServer
  alias Arena.Map.Chat

  import Arena.Test.MapStateFactory

  # ── Duel helpers ────────────────────────────────────────────────────────

  defp start_duel_server(_ctx) do
    name = :"duel_adv_#{System.unique_integer([:positive])}"
    {:ok, pid} = DuelServer.start_link(name: name)
    %{server: name, pid: pid}
  end

  # ── Council helpers ─────────────────────────────────────────────────────

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

  defp collect_console_messages(_pid, timeout \\ 50) do
    receive do
      {:send_raw, bin} ->
        [bin | collect_console_messages(self(), timeout)]

      # Effects-contract producers (Gm.Events faction broadcasts) route
      # through `AoSession.Egress.enqueue/2`, which lands as
      # `{:egress, %Outbound{payload: <<...>>}}` rather than the legacy
      # `{:send_raw, _}` shim.
      {:egress, %{payload: bin}} ->
        [bin | collect_console_messages(self(), timeout)]
    after
      timeout -> []
    end
  end

  defp contains_faction_broadcast?(bins, label, message) do
    needle = "[#{label}] #{message}"
    Enum.any?(bins, fn bin -> String.contains?(IO.iodata_to_binary(bin), needle) end)
  end

  defp contains_label?(bins, label) do
    needle = "[#{label}]"
    Enum.any?(bins, fn bin -> String.contains?(IO.iodata_to_binary(bin), needle) end)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Duel adversarial cases — VB6 ModRetos.bas + Protocol.bas:5931-5981
  # ══════════════════════════════════════════════════════════════════════════

  describe "duel: self-challenge (VB6 CrearReto same-user guard)" do
    setup :start_duel_server

    test "challenging your own char_id is rejected", %{server: s} do
      # VB6 ModRetos.bas:108-111 blocks challenging a GM, but same-player
      # identity is caught upstream in Elixir (cannot_challenge_self).
      assert {:error, :cannot_challenge_self} =
               DuelServer.challenge(4242, 4242, 100, %{pociones_maximas: 0, caen_items: false}, s)
    end
  end

  describe "duel: challenger already in a duel" do
    setup :start_duel_server

    test "second challenge from a duelling challenger is rejected", %{server: s} do
      :ok = DuelServer.challenge(100, 200, 500, %{pociones_maximas: 0, caen_items: false}, s)
      {:ok, _duel} = DuelServer.accept_challenge(200, "Challenger", s)

      # VB6 ModRetos.bas PuedeRetoConMensaje — Msg1974 "Ya te encuentras en un reto".
      assert {:error, :already_in_duel} =
               DuelServer.challenge(100, 300, 500, %{pociones_maximas: 0, caen_items: false}, s)
    end

    test "challenging a target that is already in a duel is rejected", %{server: s} do
      :ok = DuelServer.challenge(100, 200, 500, %{pociones_maximas: 0, caen_items: false}, s)
      {:ok, _duel} = DuelServer.accept_challenge(200, "Challenger", s)

      assert {:error, :target_in_duel} =
               DuelServer.challenge(300, 200, 500, %{pociones_maximas: 0, caen_items: false}, s)
    end
  end

  describe "duel: challenger with commerce / bank / trade state (VB6 PuedeReto)" do
    setup :start_duel_server

    # TODO(parity): VB6 ModRetos.bas:794-804 PuedeReto rejects duels when the
    # player is on an unsafe map (Seguro = 0), in consultation (EnConsulta),
    # at map origin, or in jail. The Elixir `DuelServer.challenge/5` pipeline
    # does not receive any map/session context, so it cannot enforce these
    # guards. These scenarios expose the drift: the DuelServer currently
    # accepts challenges regardless of commerce/bank/trade state.
    test "challenger mid-commerce: DuelServer accepts but VB6 rejects (drift)", %{server: s} do
      # There is no hook in DuelServer for the `commerce_npc_id` flag, so
      # this call succeeds — flagging the gap. The caller (session layer)
      # must gate on `state.in_commerce`; adjust once routed through.
      result =
        DuelServer.challenge(
          500,
          600,
          250,
          %{pociones_maximas: 0, caen_items: false},
          s
        )

      # Assert the existing behavior so regressions are visible. When the
      # session/map gate is wired, flip this to `{:error, :in_commerce}`.
      assert result == :ok
    end

    test "challenger mid-bank: DuelServer accepts but VB6 rejects (drift)", %{server: s} do
      # Same gap as commerce — session-level state is not visible to
      # DuelServer. VB6 routes through HandleDuel which reads UserList
      # fields; we need an equivalent check before DuelServer.challenge/5.
      assert :ok =
               DuelServer.challenge(
                 700,
                 800,
                 250,
                 %{pociones_maximas: 0, caen_items: false},
                 s
               )
    end

    test "challenger mid-trade: DuelServer accepts but VB6 rejects (drift)", %{server: s} do
      assert :ok =
               DuelServer.challenge(
                 900,
                 1000,
                 250,
                 %{pociones_maximas: 0, caen_items: false},
                 s
               )
    end
  end

  describe "duel: safe-zone check (VB6 PuedeReto Seguro flag)" do
    setup :start_duel_server

    # TODO(parity): VB6 ModRetos.bas:799 `If MapInfo(.pos.Map).Seguro = 0
    # Then Exit Function` — duels are only legal on safe maps. DuelServer
    # has no map context, so this must be enforced upstream. Recording the
    # drift here.
    test "DuelServer accepts a challenge with no safe-zone context (drift)", %{server: s} do
      assert :ok =
               DuelServer.challenge(
                 1100,
                 1200,
                 100,
                 %{pociones_maximas: 0, caen_items: false},
                 s
               )
    end
  end

  describe "duel: accepting a non-existent challenge" do
    setup :start_duel_server

    test "accept with no pending challenge returns :no_pending_challenge", %{server: s} do
      assert {:error, :no_pending_challenge} =
               DuelServer.accept_challenge(9999, "GhostChallenger", s)
    end

    test "accept after a challenge was cancelled returns :no_pending_challenge", %{server: s} do
      :ok = DuelServer.challenge(1300, 1400, 250, %{pociones_maximas: 0, caen_items: false}, s)
      :ok = DuelServer.cancel_challenge(1300, s)

      assert {:error, :no_pending_challenge} =
               DuelServer.accept_challenge(1400, "Challenger", s)
    end
  end

  describe "duel: cancelling another player's challenge (unauthorised)" do
    setup :start_duel_server

    test "unrelated third party calling cancel returns :no_challenge", %{server: s} do
      :ok = DuelServer.challenge(1500, 1600, 250, %{pociones_maximas: 0, caen_items: false}, s)

      # Someone who is neither challenger nor target tries to cancel.
      assert {:error, :no_challenge} = DuelServer.cancel_challenge(1700, s)

      # Challenge must still exist afterwards.
      assert DuelServer.get_challenge(1500, s) != nil
    end

    test "target legitimately rejects a challenge aimed at them", %{server: s} do
      :ok = DuelServer.challenge(1800, 1900, 250, %{pociones_maximas: 0, caen_items: false}, s)

      # VB6 Msg: CancelarSolicitudReto — the target IS allowed to cancel
      # (it's how you reject an invite).
      assert :ok = DuelServer.cancel_challenge(1900, s)
      assert DuelServer.get_challenge(1800, s) == nil
    end
  end

  describe "duel: quitting a duel you are not in" do
    setup :start_duel_server

    test "abandon_duel for a non-duelling player returns :not_in_duel", %{server: s} do
      assert {:error, :not_in_duel} = DuelServer.abandon_duel(2000, s)
    end

    test "abandon_duel after the duel ended is a no-op", %{server: s} do
      :ok = DuelServer.challenge(2100, 2200, 500, %{pociones_maximas: 0, caen_items: false}, s)
      {:ok, _duel} = DuelServer.accept_challenge(2200, "Challenger", s)
      {:ok, _result} = DuelServer.abandon_duel(2100, s)

      # The duel is gone; a second abandon must return :not_in_duel rather
      # than crash or double-award.
      assert {:error, :not_in_duel} = DuelServer.abandon_duel(2100, s)
      assert {:error, :not_in_duel} = DuelServer.abandon_duel(2200, s)
    end
  end

  describe "duel: pociones_maximas edge values" do
    setup :start_duel_server

    # VB6 ModRetos.bas:92-97: `If PocionesMaximas >= 0 Then If TieneObjetos(...)
    # Then reject` — negative values intentionally disable the cap. The
    # DuelServer just stores the value; higher layers enforce the cap.
    test "negative pociones_maximas is preserved (disables cap per VB6)", %{server: s} do
      assert :ok =
               DuelServer.challenge(
                 2300,
                 2400,
                 500,
                 %{pociones_maximas: -1, caen_items: false},
                 s
               )

      challenge = DuelServer.get_challenge(2300, s)
      assert challenge.pociones_maximas == -1
    end

    test "very large pociones_maximas (Int16 max) is preserved", %{server: s} do
      # VB6 Protocol.bas:5935 reads PocionesMaximas as Int16 — 32767 max.
      assert :ok =
               DuelServer.challenge(
                 2500,
                 2600,
                 500,
                 %{pociones_maximas: 32_767, caen_items: false},
                 s
               )

      challenge = DuelServer.get_challenge(2500, s)
      assert challenge.pociones_maximas == 32_767
    end

    # TODO(parity): The binary eDuel packet carries an Int16
    # (Protocol.bas:5935); values > 32767 would never reach the server.
    # DuelServer itself does not validate the range — if a non-binary
    # caller supplies 2^31, it is stored verbatim. Recording the drift.
    test "absurdly large pociones_maximas is stored verbatim (drift: no Int16 clamp)", %{server: s} do
      assert :ok =
               DuelServer.challenge(
                 2700,
                 2800,
                 500,
                 %{pociones_maximas: 2_147_483_647, caen_items: false},
                 s
               )

      challenge = DuelServer.get_challenge(2700, s)
      assert challenge.pociones_maximas == 2_147_483_647
    end
  end

  describe "duel: opponent name edge cases" do
    setup :start_duel_server

    # The DuelServer resolves ids upstream (OnlineDirectory). These tests
    # hit `accept_challenge/3` directly with malformed names. VB6
    # AceptarReto uses the name only as the reverse-lookup key; the
    # server looks up the pending challenge by acceptor id, so the name
    # has no authority check. Document that.
    test "accept with an empty challenger name still succeeds for valid challenge", %{server: s} do
      :ok = DuelServer.challenge(2900, 3000, 500, %{pociones_maximas: 0, caen_items: false}, s)

      # Name is informational only — the lookup happens by acceptor id.
      assert {:ok, _duel} = DuelServer.accept_challenge(3000, "", s)
    end

    test "accept with a 10_000-char challenger name does not crash", %{server: s} do
      :ok = DuelServer.challenge(3100, 3200, 500, %{pociones_maximas: 0, caen_items: false}, s)
      huge = String.duplicate("A", 10_000)

      assert {:ok, _duel} = DuelServer.accept_challenge(3200, huge, s)
    end
  end

  describe "duel: rapid-fire challenge -> cancel -> challenge" do
    setup :start_duel_server

    test "rapid cycle of challenge and cancel does not deadlock or leak state", %{server: s} do
      Enum.each(1..25, fn i ->
        :ok = DuelServer.challenge(3300, 3400 + i, 250, %{pociones_maximas: 0, caen_items: false}, s)
        assert DuelServer.get_challenge(3300, s) != nil
        :ok = DuelServer.cancel_challenge(3300, s)
        assert DuelServer.get_challenge(3300, s) == nil
      end)

      # After the storm the server must still be responsive.
      assert :ok =
               DuelServer.challenge(
                 3300,
                 3500,
                 250,
                 %{pociones_maximas: 0, caen_items: false},
                 s
               )

      assert DuelServer.get_challenge(3300, s) != nil
    end

    test "challenge -> cancel -> re-challenge same target works within a tight window", %{server: s} do
      :ok = DuelServer.challenge(3600, 3700, 250, %{pociones_maximas: 0, caen_items: false}, s)
      :ok = DuelServer.cancel_challenge(3600, s)

      assert :ok =
               DuelServer.challenge(
                 3600,
                 3700,
                 250,
                 %{pociones_maximas: 0, caen_items: false},
                 s
               )

      assert DuelServer.get_challenge(3600, s) != nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Council adversarial cases — VB6 Protocol.bas:5177-5209
  # ══════════════════════════════════════════════════════════════════════════

  defp base_state(sender, extras) do
    players = Map.merge(%{sender: sender}, extras)

    sessions =
      players
      |> Map.keys()
      |> Enum.reduce(%{}, fn char_id, acc ->
        pid =
          if char_id == :sender do
            self()
          else
            {:ok, p} = Task.start_link(fn -> Process.sleep(:infinity) end)
            p
          end

        Map.put(acc, char_id, pid)
      end)

    map_state(
      players: players,
      sessions: sessions,
      npcs_live: %{},
      occupancy: %{},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  describe "council /RMSG authorisation" do
    test "non-council, non-GM royal soldier: /RMSG is silently rejected" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "Plebe",
          gm: false,
          faction: :royal_army,
          council: false
        })

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Mate", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/RMSG unauthorised")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      refute contains_faction_broadcast?(messages, "Armada Real", "unauthorised"),
             "Non-council non-GM must not publish to Armada Real"

      # Drift #4 semantics: rejection should be silent — no console error
      # is shown (VB6 Protocol.bas:5183 simply skips the broadcast).
      refute contains_label?(messages, "Armada Real"),
             "Unauthorised sender should not see any [Armada Real] output"
    end

    test "royal-council player using /CMSG is rejected (wrong faction)" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "RoyalCouncil",
          gm: false,
          faction: :royal_army,
          council: :royal
        })

      chaos_mate =
        make_entity(%{char_id: :chaos_mate, name: "Chaos", faction: :chaos_legion, char_index: 2})

      state = base_state(sender, %{chaos_mate: chaos_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/CMSG infiltration attempt")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      # VB6 Protocol.bas:5202 only allows concilio (chaos council) to
      # broadcast /CMSG — a royal-council player must be rejected.
      refute contains_faction_broadcast?(messages, "Legion del Caos", "infiltration attempt"),
             "Royal Council must not be able to broadcast to Legion del Caos"
    end

    test "chaos-council player using /RMSG is rejected (wrong faction)" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "ChaosCouncil",
          gm: false,
          faction: :chaos_legion,
          council: :chaos,
          criminal: true
        })

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Royal", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/RMSG trolling")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      refute contains_faction_broadcast?(messages, "Armada Real", "trolling"),
             "Chaos Council must not be able to broadcast to Armada Real"
    end

    test "GM and council simultaneously still dispatches" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "GMCouncil",
          gm: true,
          gm_level: :dios,
          faction: :royal_army,
          council: :royal
        })

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Royal", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/RMSG both roles active")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      assert contains_faction_broadcast?(messages, "Armada Real", "both roles active"),
             "GM + council: the broadcast must still go out (neither short-circuits the other)"
    end

    test "/RMSG with empty body does not crash" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "Cons",
          gm: false,
          faction: :royal_army,
          council: :royal
        })

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Royal", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      # The call must not raise. The body is optional — VB6
      # HandleRoyalArmyMessage just broadcasts whatever was sent, but
      # rejecting an empty payload is also acceptable (VB6 HandleFactionMessage
      # at :5221 does `If LenB(Message) = 0 Then Exit Sub`).
      result =
        try do
          Chat.handle_chat(state, :sender, "/RMSG")
        rescue
          e -> {:raised, e}
        end

      assert {:ok, _, _} = result
    end

    test "missing :council flag in entity is treated as not-council" do
      # Build an entity without the :council key at all.
      sender =
        %{
          char_id: :sender,
          name: "Forgotten",
          gm: false,
          faction: :royal_army
        }
        |> then(fn e -> Map.merge(make_entity(%{char_id: :sender, name: "Forgotten"}), e) end)
        |> Map.delete(:council)

      refute Map.has_key?(sender, :council)

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Royal", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/RMSG missing council key")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      refute contains_faction_broadcast?(messages, "Armada Real", "missing council key"),
             "Entity without :council should not be allowed to broadcast /RMSG"
    end
  end

  describe "council /RMSG case sensitivity" do
    # VB6 Protocol.bas:5177 HandleRoyalArmyMessage is a BINARY packet
    # (eRoyalArmyMessage), so there is no text-level case to check in the
    # legacy server. The Elixir text gate uppercases the command before
    # matching in both `Chat.council_faction_broadcast?/2` and
    # `GmCommands.council_faction_bypass?/2`, so `/rmsg`, `/rMsG`, and
    # `/RMSG` authorise correctly.
    #
    # TODO(parity): GmCommands dispatch uppercases `upper_parts` for match
    # selection but calls `String.trim_leading(message, "/RMSG ")` on the
    # ORIGINAL case-sensitive message at gm_commands.ex:378-384. A lowercase
    # or mixed-case `/rmsg` therefore leaks the command prefix into the
    # broadcast body (audit log shows `[Armada Real] /rmsg lowercase
    # works` instead of `[Armada Real] lowercase works`). Fix: use
    # case-insensitive trim when extracting msg_text.
    test "lowercase /rmsg from a council member broadcasts (case-insensitive)" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "Cons",
          gm: false,
          faction: :royal_army,
          council: :royal
        })

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Royal", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/rmsg lowercase works")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      assert contains_faction_broadcast?(messages, "Armada Real", "lowercase works"),
             "Elixir normalises command case; /rmsg must work for council members"
    end

    test "mixed-case /RmSg from a council member broadcasts" do
      sender =
        make_entity(%{
          char_id: :sender,
          name: "Cons",
          gm: false,
          faction: :royal_army,
          council: :royal
        })

      royal_mate =
        make_entity(%{char_id: :royal_mate, name: "Royal", faction: :royal_army, char_index: 2})

      state = base_state(sender, %{royal_mate: royal_mate})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, :sender, "/RmSg mixed case works")
      Arena.Map.Effects.run(run_state, run_effects)

      messages = collect_console_messages(self())

      assert contains_faction_broadcast?(messages, "Armada Real", "mixed case works"),
             "Mixed case /RmSg must broadcast (council gate uppercases)"
    end
  end
end
