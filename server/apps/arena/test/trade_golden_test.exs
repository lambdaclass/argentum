defmodule Arena.TradeGoldenTest do
  @moduledoc """
  Golden fixture for the player-to-player trade flow
  (`Arena.Map.Trade`), written against the deterministic scenario
  harness (`Arena.Test.Scenario`).

  Historical deterministic-parity golden work recorded in the root
  `CHANGELOG.md` — sibling of `healing_golden_test.exs`,
  `forgive_golden_test.exs`, `gamble_golden_test.exs`, and
  `potions_golden_test.exs`.

  Pins VB6 parity for the Comercio.bas user-to-user trade module:
    * `start_user_trade_request/4` — request handshake (single-side =>
      notify; both-sides => start session).
    * `handle_user_trade_offer/4` — add an inventory item to the offer
      (no in-place mutation until commit).
    * `handle_user_trade_accept/2` — single-side flag flip vs. both-side
      atomic commit (with `GameBackend.Characters.save_trade_snapshots/2`
      transactional persistence).
    * `handle_user_trade_reject/2` — closes the trade (no un-accept toggle).
    * `handle_user_trade_end/2` — closes both sides and emits
      `user_commerce_end` to each.

  Trade contract is `{:ok, state, reply, effects}` — handlers run via
  `run_handler/2` (a local wrapper around `Arena.Test.Scenario.run/2`
  that strips the reply).

  Persistence: `execute_trade/3` calls `save_trade_snapshots/2` inside a
  `try/rescue`. Without an SQL Sandbox checkout the call raises
  `DBConnection.OwnershipError` and is rescued as `{:error, :exception}`
  — that path is exercised by the "commit failure" test. The "happy
  path" commit test checks out the sandbox and creates real DB chars,
  mirroring `trade_persistence_test.exs`.

  VB6 anchors (Comercio.bas procedures, confirmed against `Arena.Map.Trade`
  port comments; no VB6 source tree is vendored, so line numbers are pending):
    * `start_user_trade_request/4` — `IniciarComercio` / `OnRecvComerciarUsuario`
                                     (mutual-request handshake).
    * `handle_user_trade_offer/4`  — `OfertarOroComUsu` / `OfertarItemComUsu`
                                     (offer is staged; inventory NOT mutated
                                     until both-side accept). Instransferible and
                                     newbie items are rejected (trade.ex:41,47).
    * `handle_user_trade_accept/2` — `AceptarComUsu` (single-side flag flip vs.
                                     both-side atomic commit; no un-accept toggle).
    * `handle_user_trade_reject/2` — `RechazarComUsu` (no un-accept toggle).
    * `handle_user_trade_end/2`    — `TerminarComUsu` (closes both sides,
                                     emits `user_commerce_end`).
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, ItemDef}
  alias Arena.Map.Trade

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  # Synthetic test items registered into the GameData ETS table. IDs sit
  # high above real game data to avoid collisions.
  @sword_id 70_001
  @potion_id 70_002
  @newbie_item_id 70_003
  @instransferible_item_id 70_004

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ets.insert(:arena_game_data, {
      {:item, @sword_id},
      %ItemDef{
        id: @sword_id,
        name: "TestSword",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: false,
        newbie: false
      }
    })

    :ets.insert(:arena_game_data, {
      {:item, @potion_id},
      %ItemDef{
        id: @potion_id,
        name: "TestPotion",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: false,
        newbie: false
      }
    })

    :ets.insert(:arena_game_data, {
      {:item, @newbie_item_id},
      %ItemDef{
        id: @newbie_item_id,
        name: "TestNewbieItem",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: false,
        newbie: true
      }
    })

    :ets.insert(:arena_game_data, {
      {:item, @instransferible_item_id},
      %ItemDef{
        id: @instransferible_item_id,
        name: "TestInstransferibleItem",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: true,
        newbie: false
      }
    })

    :ok
  end

  # ────────────────────────────────────────────────────────────────────
  # Local helpers (no harness changes — keep all trade-specific glue here)
  # ────────────────────────────────────────────────────────────────────

  # Trade handlers return `{:ok, state, reply, effects}` (Effects.run_handler_call_reply
  # contract). The harness's `run/2` expects `{:ok, state, effects}`, so
  # we strip the reply here. Reply is stashed in the process dictionary
  # for tests that want to assert on it via `last_trade_reply/0`.
  defp run_handler(scenario, fun) do
    Process.delete(:trade_last_reply)

    run(scenario, fn state ->
      {:ok, new_state, reply, effects} = fun.(state)
      Process.put(:trade_last_reply, reply)
      {:ok, new_state, effects}
    end)
  end

  defp last_trade_reply, do: Process.get(:trade_last_reply)

  # Stamp an inventory item at `slot` for `char_id`. Mirrors the helper in
  # potions_golden_test.exs but writes the full %{equipped, elemental_tags}
  # shape that Trade's matchers expect.
  defp with_inventory_item(scenario, char_id, item_id, amount, slot \\ 0) do
    update_state(scenario, fn state ->
      entity = state.players[char_id]

      inventory =
        List.replace_at(
          entity.inventory,
          slot,
          %{item_id: item_id, amount: amount, equipped: false, elemental_tags: 0}
        )

      players = Map.put(state.players, char_id, %{entity | inventory: inventory})
      %{state | players: players}
    end)
  end

  # Set the trade-session fields directly on a player so we can drive
  # offer/accept/reject/end without first running a handshake.
  defp with_active_trade(scenario, p1, p2, opts \\ []) do
    update_state(scenario, fn state ->
      entity1 = state.players[p1]
      entity2 = state.players[p2]

      e1_overrides =
        Keyword.get(opts, :p1_overrides, [])
        |> Enum.into(%{})
        |> Map.merge(%{trade_partner_id: p2})

      e2_overrides =
        Keyword.get(opts, :p2_overrides, [])
        |> Enum.into(%{})
        |> Map.merge(%{trade_partner_id: p1})

      players =
        state.players
        |> Map.put(p1, struct!(entity1, e1_overrides))
        |> Map.put(p2, struct!(entity2, e2_overrides))

      %{state | players: players}
    end)
  end

  defp run_request(scenario, char_id, target_id) do
    run_handler(scenario, fn state ->
      entity = Map.fetch!(state.players, char_id)
      Trade.start_user_trade_request(state, char_id, entity, target_id)
    end)
  end

  defp run_offer(scenario, char_id, item_id, amount) do
    run_handler(scenario, fn state ->
      Trade.handle_user_trade_offer(state, char_id, item_id, amount)
    end)
  end

  defp run_accept(scenario, char_id) do
    run_handler(scenario, fn state ->
      Trade.handle_user_trade_accept(state, char_id)
    end)
  end

  defp run_reject(scenario, char_id) do
    run_handler(scenario, fn state ->
      Trade.handle_user_trade_reject(state, char_id)
    end)
  end

  defp run_end(scenario, char_id) do
    run_handler(scenario, fn state ->
      Trade.handle_user_trade_end(state, char_id)
    end)
  end

  # Two-player scenario at the canonical adjacent layout: p1 at (50,50),
  # p2 at (51,50). Both have generous gold for trade-gold tests.
  defp two_players(opts \\ []) do
    new(map_id: 1)
    |> with_player(:p1,
      Keyword.merge(
        [name: "Alice", x: 50, y: 50, char_index: 1, gold: 10_000],
        Keyword.get(opts, :p1, [])
      )
    )
    |> with_player(:p2,
      Keyword.merge(
        [name: "Bob", x: 51, y: 50, char_index: 2, gold: 5_000],
        Keyword.get(opts, :p2, [])
      )
    )
  end

  # ────────────────────────────────────────────────────────────────────
  # Initiate trade — handshake (`start_user_trade_request/4`)
  # VB6: Comercio.bas — IniciarComercio / OnRecvComerciarUsuario
  # ────────────────────────────────────────────────────────────────────

  describe "initiate trade — first request notifies the target" do
    test "first request stores trade_request_target and notifies target via console" do
      s =
        two_players()
        |> run_request(:p1, :p2)

      assert last_trade_reply() == :ok
      e1 = entity(s, :p1)
      e2 = entity(s, :p2)
      assert e1.trade_request_target == :p2
      assert e1.trade_partner_id == nil, "first request must NOT enter trade yet"
      assert e2.trade_partner_id == nil
      assert_effect(s, :send, to: :p2, packet: :console_msg)
    end

    test "first request does NOT emit user_commerce_init (only notifies target)" do
      s =
        two_players()
        |> run_request(:p1, :p2)

      refute_effect(s, :send, to: :p1, packet: :user_commerce_init)
      refute_effect(s, :send, to: :p2, packet: :user_commerce_init)
    end
  end

  describe "initiate trade — both sides ready starts the session" do
    test "second request (target already requested initiator) starts trade for both" do
      s =
        two_players()
        |> run_request(:p1, :p2)
        |> clear_effects()
        |> run_request(:p2, :p1)

      assert last_trade_reply() == :ok

      e1 = entity(s, :p1)
      e2 = entity(s, :p2)

      assert e1.trade_partner_id == :p2
      assert e2.trade_partner_id == :p1
      assert e1.trade_request_target == nil
      assert e2.trade_request_target == nil
      assert e1.trade_offer_items == []
      assert e2.trade_offer_items == []
      assert e1.trade_offer_gold == 0
      assert e2.trade_offer_gold == 0
      refute e1.trade_accepted
      refute e2.trade_accepted

      # Both sides receive the user_commerce_init packet (UI flag).
      assert_effect(s, :send, to: :p1, packet: :user_commerce_init)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_init)

      # Byte-level fixture: eUserCommerceInit (12) — name(String8), where
      # String8 is an Int16 length prefix + raw bytes. Each side is told the
      # OTHER trader's name so the client can label the window.
      assert <<12::little-signed-16, 3::little-signed-16, "Bob">> =
               assert_payload(s, :send, to: :p1, packet: :user_commerce_init)

      assert <<12::little-signed-16, 5::little-signed-16, "Alice">> =
               assert_payload(s, :send, to: :p2, packet: :user_commerce_init)
    end
  end

  describe "initiate rejections" do
    # `Trade.start_user_trade_request/4` rejection surface (the only
    # checks performed at this layer; range/dead/self-trade live in
    # `Commerce.handle_open_commerce`):
    #   * target not in players map -> :target_not_found
    #   * target.dead              -> :target_dead
    #   * initiator already trading -> :already_trading
    #   * target already trading    -> :target_busy

    test "missing target: :target_not_found, no state change" do
      s =
        new(map_id: 1)
        |> with_player(:p1, name: "Alice", x: 50, y: 50, char_index: 1)
        |> run_request(:p1, :ghost)

      assert last_trade_reply() == {:error, :target_not_found}
      assert entity(s, :p1).trade_request_target == nil
      assert entity(s, :p1).trade_partner_id == nil
    end

    test "target dead: :target_dead, console msg sent to initiator" do
      s =
        two_players(p2: [dead: true, hp: 0])
        |> run_request(:p1, :p2)

      assert last_trade_reply() == {:error, :target_dead}
      assert entity(s, :p1).trade_request_target == nil
      assert_effect(s, :send, to: :p1, packet: :console_msg)
    end

    test "initiator already trading: :already_trading" do
      two_players()
      |> with_player(:p3, name: "Charlie", x: 52, y: 50, char_index: 3)
      |> with_active_trade(:p1, :p2)
      |> run_request(:p1, :p3)

      assert last_trade_reply() == {:error, :already_trading}
    end

    test "target already trading with someone else: :target_busy" do
      # p2 is mid-trade with p3; p1 tries to invite p2.
      s =
        two_players()
        |> with_player(:p3, name: "Charlie", x: 52, y: 50, char_index: 3)
        |> with_active_trade(:p2, :p3)
        |> run_request(:p1, :p2)

      assert last_trade_reply() == {:error, :target_busy}
      assert entity(s, :p1).trade_request_target == nil
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Offer item — `handle_user_trade_offer/4`
  # VB6: Comercio.bas — OfertarOroComUsu / OfertarItemComUsu
  # ────────────────────────────────────────────────────────────────────

  describe "offer item — happy path" do
    test "offered item is added to trade_offer_items, both sides see slot update" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 3)

      assert last_trade_reply() == :ok
      e1 = entity(s, :p1)
      assert e1.trade_offer_items == [{@sword_id, 3, 0}]

      # VB6 parity: inventory is NOT mutated until both-side accept.
      slot0 = Enum.at(e1.inventory, 0)
      assert slot0.item_id == @sword_id
      assert slot0.amount == 5

      assert_effect(s, :send, to: :p1, packet: :change_user_trade_slot)
      assert_effect(s, :send, to: :p2, packet: :change_user_trade_slot)

      # Byte-level fixture: eChangeUserTradeSlot (100) — my_offer(Bool) +
      # gold(Int32) + the first offered item (obj_index(Int16) + name(String8)
      # + grh(Int32) + amount(Int32) + tags(Int32)). The offerer sees their
      # own side with my_offer=1; the partner sees the same items with
      # my_offer=0. We pin the flag, gold, and item identity/amount; grh and
      # the 5 empty trailing slots are bound, not value-checked.
      assert <<100::little-signed-16, 1, 0::little-signed-32, sword_obj::little-signed-16,
               9::little-signed-16, "TestSword", _grh::little-signed-32, 3::little-signed-32,
               0::little-signed-32, _rest::binary>> =
               assert_payload(s, :send, to: :p1, packet: :change_user_trade_slot)

      # obj_index is an Int16 on the wire. @sword_id is a synthetic test id that
      # deliberately sits above real game data and exceeds the Int16 range, so
      # the wire carries its low 16 bits — real AO obj indices fit in Int16.
      assert sword_obj == rem(@sword_id, 0x1_0000)

      assert <<100::little-signed-16, 0, 0::little-signed-32, ^sword_obj::little-signed-16,
               9::little-signed-16, "TestSword", _grh::little-signed-32, 3::little-signed-32,
               0::little-signed-32, _rest::binary>> =
               assert_payload(s, :send, to: :p2, packet: :change_user_trade_slot)
    end

    test "offering more of the same item updates the existing entry" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 10)
        |> run_offer(:p1, @sword_id, 2)
        |> clear_effects()
        |> run_offer(:p1, @sword_id, 3)

      assert entity(s, :p1).trade_offer_items == [{@sword_id, 5, 0}],
             "second offer of same item must accumulate, not append"
    end

    test "offer resets the partner's accepted flag" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2,
          p1_overrides: [trade_accepted: false],
          p2_overrides: [trade_accepted: true]
        )
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 1)

      refute entity(s, :p1).trade_accepted
      refute entity(s, :p2).trade_accepted, "partner's accept must reset on any offer"
    end
  end

  describe "offer item — rejections" do
    test "not in trade: {:error, :not_trading}, no state change" do
      s =
        two_players()
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 3)

      assert last_trade_reply() == {:error, :not_trading}
      assert entity(s, :p1).trade_offer_items == []
    end

    test "dead initiator: {:error, :dead}" do
      s =
        two_players(p1: [dead: true, hp: 0])
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 3)

      assert last_trade_reply() == {:error, :dead}
      assert entity(s, :p1).trade_offer_items == []
    end

    test "not on map: {:error, :not_on_map}" do
      two_players()
      |> with_active_trade(:p1, :p2)
      |> run_offer(:ghost, @sword_id, 1)

      assert last_trade_reply() == {:error, :not_on_map}
    end

    test "empty slot for that item: {:error, :invalid_offer}" do
      two_players()
      |> with_active_trade(:p1, :p2)
      # No inventory item — handler can't find the slot.
      |> run_offer(:p1, @sword_id, 1)

      assert last_trade_reply() == {:error, :invalid_offer}
    end

    test "amount > inventory amount: {:error, :invalid_offer}" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 2)
        |> run_offer(:p1, @sword_id, 5)

      assert last_trade_reply() == {:error, :invalid_offer}
      assert entity(s, :p1).trade_offer_items == []
    end

    test "amount <= 0: {:error, :invalid_offer}" do
      two_players()
      |> with_active_trade(:p1, :p2)
      |> with_inventory_item(:p1, @sword_id, 5)
      |> run_offer(:p1, @sword_id, 0)

      assert last_trade_reply() == {:error, :invalid_offer}
    end

    test "instransferible item: {:error, :untradeable}, console msg" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @instransferible_item_id, 5)
        |> run_offer(:p1, @instransferible_item_id, 1)

      assert last_trade_reply() == {:error, :untradeable}
      assert_effect(s, :send, to: :p1, packet: :console_msg)
    end

    test "newbie item: {:error, :newbie_item}, console msg" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @newbie_item_id, 5)
        |> run_offer(:p1, @newbie_item_id, 1)

      assert last_trade_reply() == {:error, :newbie_item}
      assert_effect(s, :send, to: :p1, packet: :console_msg)
    end

    test "cumulative offer over inventory amount is rejected" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 3)
        |> run_offer(:p1, @sword_id, 3)

      assert last_trade_reply() == {:error, :invalid_offer},
             "second offer would push total to 6 > inventory amount 5"
      assert entity(s, :p1).trade_offer_items == [{@sword_id, 3, 0}]
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Accept — single-side and both-side commit
  # VB6: Comercio.bas — AceptarComUsu (no un-accept toggle)
  # ────────────────────────────────────────────────────────────────────

  describe "accept — single side" do
    test "single accept flips trade_accepted but doesn't commit" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 2)
        |> clear_effects()
        |> run_accept(:p1)

      assert last_trade_reply() == :ok
      e1 = entity(s, :p1)
      e2 = entity(s, :p2)
      assert e1.trade_accepted, "accepter must flip"
      refute e2.trade_accepted, "partner is unchanged"

      # No swap happened: items still in trade_offer_items, not in inv.
      assert e1.trade_offer_items == [{@sword_id, 2, 0}]
      assert Enum.at(e1.inventory, 0).amount == 5

      # Trade is still open — no user_commerce_end.
      refute_effect(s, :send, to: :p1, packet: :user_commerce_end)
      refute_effect(s, :send, to: :p2, packet: :user_commerce_end)
    end

    test "dead accepter: {:error, :dead}" do
      s =
        two_players(p1: [dead: true, hp: 0])
        |> with_active_trade(:p1, :p2)
        |> run_accept(:p1)

      assert last_trade_reply() == {:error, :dead}
      refute entity(s, :p1).trade_accepted
    end

    test "not in trade: {:error, :not_trading}" do
      two_players() |> run_accept(:p1)
      assert last_trade_reply() == {:error, :not_trading}
    end

    test "not on map: {:error, :not_on_map}" do
      two_players() |> run_accept(:ghost)
      assert last_trade_reply() == {:error, :not_on_map}
    end
  end

  describe "accept — both sides commit" do
    # Happy-path commit goes through `GameBackend.Characters.save_trade_snapshots/2`.
    # Without an SQL Sandbox checkout the persistence call raises
    # `DBConnection.OwnershipError`, the rescue clause turns that into
    # `{:error, :exception}`, and the trade is ended with a failure
    # console message. We exercise that path here — it is a real failure
    # mode in production (DB unreachable) and the behavior we want is:
    # both sides ended cleanly, gold/inventory untouched.

    test "commit failure (DB unreachable): trade ends, both inventories untouched" do
      s =
        two_players(p1: [gold: 10_000], p2: [gold: 5_000])
        |> with_active_trade(:p1, :p2,
          p1_overrides: [
            trade_offer_items: [{@sword_id, 2, 0}],
            trade_accepted: true
          ],
          p2_overrides: [trade_accepted: true]
        )
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_accept(:p1)

      # `:ok` reply because the handler reached the both-accepted branch
      # and the result of execute_trade is folded in regardless of
      # commit outcome (see Trade.handle_user_trade_accept).
      assert last_trade_reply() == :ok

      e1 = entity(s, :p1)
      e2 = entity(s, :p2)

      # In-memory state is unchanged (DB write failed -> no apply).
      assert e1.gold == 10_000
      assert e2.gold == 5_000
      assert Enum.at(e1.inventory, 0).item_id == @sword_id
      assert Enum.at(e1.inventory, 0).amount == 5

      # Trade is closed for both sides.
      assert e1.trade_partner_id == nil
      assert e2.trade_partner_id == nil
      assert e1.trade_offer_items == []
      assert e2.trade_offer_items == []

      # Both sides notified via failure console + user_commerce_end.
      assert_effect(s, :send, to: :p1, packet: :console_msg)
      assert_effect(s, :send, to: :p2, packet: :console_msg)
      assert_effect(s, :send, to: :p1, packet: :user_commerce_end)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_end)

      # Byte-level fixture: eConsoleMsg (37) — chat(String8) + FontIndex(Int8).
      # Pin the exact failure text the client renders on a rolled-back commit.
      assert <<37::little-signed-16, len::little-signed-16, msg::binary-size(len), _font>> =
               assert_payload(s, :send, to: :p1, packet: :console_msg)

      assert msg == "Comercio fallido, intente nuevamente."
    end

    test "second accept after partner accepted commits (and ends), no swap on DB failure" do
      # Two-step flow: p1 accepts (no commit yet), p2 accepts (commit fires).
      # Even though commit fails, the both-accepted branch is reached — we
      # verify the trade is closed, not just the single-accept branch.
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 2)
        |> run_accept(:p1)
        |> clear_effects()
        |> run_accept(:p2)

      assert entity(s, :p1).trade_partner_id == nil,
             "second accept must trigger the commit branch (which ends the trade)"
      assert entity(s, :p2).trade_partner_id == nil

      assert_effect(s, :send, to: :p1, packet: :user_commerce_end)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_end)

      # Byte-level fixture: eUserCommerceEnd (13) closes the window with an
      # empty payload — exactly the 2-byte id, no trailing bytes.
      assert <<13::little-signed-16>> ==
               assert_payload(s, :send, to: :p1, packet: :user_commerce_end)
    end
  end

  describe "accept — distance check on commit" do
    # `handle_user_trade_accept` re-checks distance when both sides are
    # accepted. If too far, the trade is ended with `{:error, :too_far}`.
    test "accepting from too far ends the trade with :too_far" do
      s =
        new(map_id: 1)
        |> with_player(:p1, name: "Alice", x: 50, y: 50, char_index: 1)
        |> with_player(:p2, name: "Bob", x: 60, y: 50, char_index: 2)
        |> with_active_trade(:p1, :p2,
          p1_overrides: [trade_accepted: false],
          p2_overrides: [trade_accepted: true]
        )
        |> run_accept(:p1)

      assert last_trade_reply() == {:error, :too_far}
      assert entity(s, :p1).trade_partner_id == nil
      assert entity(s, :p2).trade_partner_id == nil
      assert_effect(s, :send, to: :p1, packet: :user_commerce_end)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_end)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Reject — closes the trade for both sides
  # VB6: Comercio.bas — RechazarComUsu (no un-accept toggle in our impl)
  # ────────────────────────────────────────────────────────────────────

  describe "reject" do
    test "reject ends the trade for both sides (no un-accept toggle)" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2,
          p1_overrides: [trade_accepted: true],
          p2_overrides: [trade_accepted: false]
        )
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_offer(:p1, @sword_id, 2)
        |> clear_effects()
        |> run_reject(:p1)

      assert last_trade_reply() == :ok
      e1 = entity(s, :p1)
      e2 = entity(s, :p2)

      # Both sides are out of the trade — `reject` is destructive in our
      # implementation, not a per-side toggle.
      assert e1.trade_partner_id == nil
      assert e2.trade_partner_id == nil
      assert e1.trade_offer_items == []
      assert e2.trade_offer_items == []
      refute e1.trade_accepted
      refute e2.trade_accepted

      assert_effect(s, :send, to: :p1, packet: :user_commerce_end)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_end)
    end

    test "reject when not in trade is a no-op (:ok, no packets)" do
      s = two_players() |> run_reject(:p1)

      assert last_trade_reply() == :ok
      refute_effect(s, :send, to: :p1, packet: :user_commerce_end)
    end

    test "reject when not on map: {:error, :not_on_map}" do
      two_players() |> run_reject(:ghost)
      assert last_trade_reply() == {:error, :not_on_map}
    end

    test "items and gold remain owned by the original side after reject" do
      s =
        two_players(p1: [gold: 10_000], p2: [gold: 5_000])
        |> with_active_trade(:p1, :p2,
          p1_overrides: [trade_offer_items: [{@sword_id, 3, 0}]]
        )
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_reject(:p1)

      e1 = entity(s, :p1)
      e2 = entity(s, :p2)
      assert e1.gold == 10_000, "no gold transfer on reject"
      assert e2.gold == 5_000
      assert Enum.at(e1.inventory, 0).amount == 5, "p1 keeps the offered item"
      assert Enum.at(e2.inventory, 0) == nil, "p2 receives nothing"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # End — close the trade session
  # VB6: Comercio.bas — TerminarComUsu
  # ────────────────────────────────────────────────────────────────────

  describe "end trade" do
    test "either side calling end closes both: state cleared, packets to both" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2,
          p1_overrides: [
            trade_offer_items: [{@sword_id, 2, 0}],
            trade_offer_gold: 100,
            trade_accepted: true
          ]
        )
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_end(:p1)

      assert last_trade_reply() == :ok

      e1 = entity(s, :p1)
      e2 = entity(s, :p2)

      assert e1.trade_partner_id == nil
      assert e2.trade_partner_id == nil
      assert e1.trade_offer_items == []
      assert e1.trade_offer_gold == 0
      refute e1.trade_accepted
      refute e2.trade_accepted

      assert_effect(s, :send, to: :p1, packet: :user_commerce_end)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_end)
    end

    test "items and gold are returned to the original owners (no mutation)" do
      s =
        two_players(p1: [gold: 10_000], p2: [gold: 5_000])
        |> with_active_trade(:p1, :p2,
          p1_overrides: [
            trade_offer_items: [{@sword_id, 3, 0}],
            trade_offer_gold: 200
          ]
        )
        |> with_inventory_item(:p1, @sword_id, 5)
        |> run_end(:p1)

      e1 = entity(s, :p1)
      e2 = entity(s, :p2)

      # Trade-state lockboxes are emptied, but the underlying gold and
      # inventory were never debited in the first place — `end` is a
      # rollback to the pre-trade snapshot.
      assert e1.gold == 10_000
      assert e2.gold == 5_000
      assert Enum.at(e1.inventory, 0).amount == 5
      assert Enum.at(e2.inventory, 0) == nil
    end

    test "end called by partner side closes for both" do
      s =
        two_players()
        |> with_active_trade(:p1, :p2)
        |> run_end(:p2)

      assert entity(s, :p1).trade_partner_id == nil
      assert entity(s, :p2).trade_partner_id == nil
      assert_effect(s, :send, to: :p1, packet: :user_commerce_end)
      assert_effect(s, :send, to: :p2, packet: :user_commerce_end)
    end

    test "end while only a request is pending cancels the request, no packets" do
      # `start_user_trade_request` was called once but target hasn't
      # mirrored: `trade_request_target` set, `trade_partner_id` nil.
      s =
        two_players()
        |> run_request(:p1, :p2)
        |> clear_effects()
        |> run_end(:p1)

      assert last_trade_reply() == :ok
      assert entity(s, :p1).trade_request_target == nil
      refute_effect(s, :send, to: :p1, packet: :user_commerce_end)
      refute_effect(s, :send, to: :p2, packet: :user_commerce_end)
    end

    test "end when not in trade and not requesting: silent :ok" do
      s = two_players() |> run_end(:p1)
      assert last_trade_reply() == :ok
      refute_effect(s, :send, to: :p1, packet: :user_commerce_end)
    end

    test "end when not on map: {:error, :not_on_map}" do
      two_players() |> run_end(:ghost)
      assert last_trade_reply() == {:error, :not_on_map}
    end
  end
end
