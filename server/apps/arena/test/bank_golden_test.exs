defmodule Arena.BankGoldenTest do
  @moduledoc """
  Golden fixture for the bank flow (`Arena.Map.Bank`), written against
  the deterministic scenario harness (`Arena.Test.Scenario`).

  Historical deterministic-parity golden work recorded in the root
  `CHANGELOG.md` — sibling of `gamble_golden_test.exs`,
  `forgive_golden_test.exs`, `healing_golden_test.exs`,
  `potions_golden_test.exs`. All six bank entry points
  (`handle_open_bank`, `handle_bank_deposit`, `handle_bank_extract_item`,
  `handle_bank_deposit_gold`, `handle_bank_extract_gold`,
  `handle_bank_end`) post-migration return
  `{:ok, state, reply, [Effect.t()]}` and route packet emission through
  `Arena.Map.Effects.send/2`, so we assert with the gameplay-shaped
  effect DSL rather than legacy `{:send_raw, _}` mailbox shapes.

  Bank state lives in the DB (`GameBackend.BankItems`,
  `GameBackend.Characters.bank_gold`) — it is loaded on demand and
  never cached in MapServer hot state. Every test that touches a real
  banking handler therefore needs an Ecto sandbox checkout plus a real
  character row; the helpers below mirror the pattern in
  `bank_persistence_test.exs` / `bank_stack_cap_parity_test.exs`.

  VB6 anchors:
    * `handle_open_bank`            — modBanco.bas: `HandleOpenBank` + npc_type 4 (`@npc_type_banquero`).
    * `handle_bank_deposit`         — modBanco.bas:201..261 (`Cantidad > 0`, slot bounds, stack-cap guard).
    * `handle_bank_extract_item`    — modBanco.bas:94..  (`Cantidad < 1`, empty-slot guard, inv-full rollback).
    * `handle_bank_deposit_gold`    — modBanco.bas (`HandleBankDepositGold`).
    * `handle_bank_extract_gold`    — modBanco.bas (`HandleBankExtractGold`).
    * `handle_bank_end`             — modBanco.bas (`HandleBankEnd`).
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, NpcDef, ItemDef}
  alias Arena.Map.Bank
  alias GameBackend.BankItems

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  # VB6: npc_type 4 = banquero (banker).
  @npc_type_banquero 4
  # VB6 modBanco.bas: bank inventory caps at 40 slots.
  @bank_max_slots 40

  # Stackable test items seeded into ETS. Item ids well above the live
  # obj.dat range so we can't collide with a real definition.
  @stackable_item_id 9_500
  @nonstackable_item_id 9_501
  @untradeable_item_id 9_502

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    :ets.insert(:arena_game_data, {{:npc, 700}, banker_def(700)})

    seed_item(@stackable_item_id, %{
      name: "Manzana",
      obj_type: 1,
      stackable: true,
      max_hit: 10_000,
      valor: 5
    })

    seed_item(@nonstackable_item_id, %{
      name: "Espada",
      obj_type: 2,
      stackable: false,
      valor: 100
    })

    seed_item(@untradeable_item_id, %{
      name: "Llave",
      obj_type: 1,
      stackable: true,
      max_hit: 10_000,
      valor: 0,
      instransferible: true
    })

    :ok
  end

  defp banker_def(id) do
    %NpcDef{
      id: id,
      npc_type: @npc_type_banquero,
      name: "Banquero",
      faccion: 0,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  defp seed_item(id, fields) do
    item =
      %ItemDef{id: id}
      |> Map.merge(Map.new(fields))

    :ets.insert(:arena_game_data, {{:item, id}, item})
  end

  defp with_banker(scenario, instance_id \\ :bank1, opts \\ []) do
    with_npc(scenario, instance_id, Keyword.merge([npc_id: 700, x: 51, y: 50], opts))
  end

  # Create a real character row (and hosting account) so bank handlers
  # have something to write through to. Returns the integer char_id.
  defp create_character! do
    {:ok, account} =
      GameBackend.Account.create(
        "bankgold_acc_#{:erlang.unique_integer([:positive])}",
        "password123"
      )

    {:ok, char} =
      GameBackend.Characters.create(%{
        name: "bankgold_#{:erlang.unique_integer([:positive])}",
        account_id: account.id
      })

    char.id
  end

  # Default banking entity. char_id MUST come from `create_character!/0`
  # so DB writes succeed; we reset bank_gold separately via a snapshot
  # because `Characters.create/2` initialises it to 0.
  defp banker_entity(char_id, opts \\ []) do
    Keyword.merge(
      [
        char_id: char_id,
        bank_npc_id: :bank1,
        bank_gold: 0,
        gold: 100_000,
        inventory: List.duplicate(nil, 24)
      ],
      opts
    )
  end

  # For tests that pre-set the player's bank_gold, also persist the same
  # value so that `Bank.get_bank_gold/1` (which always reads through the
  # DB on session open) matches the cached value when the test invokes
  # `handle_open_bank/4`.
  defp set_bank_gold!(char_id, amount) do
    {:ok, _} = Bank.save_bank_gold(char_id, amount)
    :ok
  end

  defp seed_bank_item!(char_id, slot, item_id, amount, tags \\ 0) do
    {:ok, _} = BankItems.upsert(char_id, slot, item_id, amount, tags)
    :ok
  end

  # Bank handlers use the rich-reply effects contract:
  # `{:ok, state, reply, effects}`. The scenario harness `run/2` expects
  # the pure `{:ok, state, effects}` shape (no reply), so we strip the
  # reply term in this thin wrapper.
  defp run_bank(scenario, fun) when is_function(fun, 1) do
    run(scenario, fn state ->
      {:ok, new_state, _reply, effects} = fun.(state)
      {:ok, new_state, effects}
    end)
  end

  defp open_session(scenario, char_id) do
    run_bank(scenario, fn state ->
      Bank.handle_open_bank(state, char_id, 51, 50)
    end)
  end

  # ════════════════════════════════════════════════════════════════════
  # handle_open_bank/4
  # VB6: modBanco.bas — HandleOpenBank, banker npc_type 4.
  # ════════════════════════════════════════════════════════════════════

  describe "handle_open_bank: happy path" do
    test "opens session, sets bank_npc_id, emits :bank_init + :update_bank_gold" do
      char_id = create_character!()
      set_bank_gold!(char_id, 250)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil))
        |> with_banker()
        |> open_session(char_id)

      e = entity(s, char_id)
      assert e.bank_npc_id == :bank1
      assert e.bank_gold == 250
      assert_effect(s, :send, to: char_id, packet: :bank_init)
      assert_effect(s, :send, to: char_id, packet: :update_bank_gold)

      # Byte-level fixture: eBankInit (11) opens the UI with an empty payload;
      # eUpdateBankGld (175) carries the loaded bank balance.
      assert <<11::little-signed-16>> == assert_payload(s, :send, to: char_id, packet: :bank_init)

      assert <<175::little-signed-16, 250::little-signed-32>> =
               assert_payload(s, :send, to: char_id, packet: :update_bank_gold)
    end

    test "with seeded bank items: emits :change_bank_slot per row" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @stackable_item_id, 5)
      seed_bank_item!(char_id, 3, @stackable_item_id, 25)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil))
        |> with_banker()
        |> open_session(char_id)

      assert_effect(s, :send, to: char_id, packet: :bank_init)
      assert_effect(s, :send, to: char_id, packet: :update_bank_gold)
      # Two seeded rows -> at least one :change_bank_slot.
      assert_effect(s, :send, to: char_id, packet: :change_bank_slot)
    end
  end

  describe "handle_open_bank: rejections" do
    test "no NPC at target tile: rejected with :no_banker, console_msg sent" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil))
        |> open_session(char_id)

      assert entity(s, char_id).bank_npc_id == nil
      assert_effect(s, :send, to: char_id, packet: :console_msg)
      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end

    test "non-banker NPC at target: rejected" do
      char_id = create_character!()
      :ets.insert(:arena_game_data, {{:npc, 701}, %{banker_def(701) | npc_type: 1}})

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil))
        |> with_banker(:bank1, npc_id: 701)
        |> open_session(char_id)

      assert entity(s, char_id).bank_npc_id == nil
      assert_effect(s, :send, to: char_id, packet: :console_msg)
      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end

    test "banker > 6 tiles away: :too_far, console_msg sent" do
      # `handle_open_bank` enforces a Chebyshev radius of 6 between the
      # player and the target tile (VB6 modBanco.bas).
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil, x: 50, y: 50))
        |> with_banker(:bank1, x: 57, y: 50)
        |> run_bank(fn state -> Bank.handle_open_bank(state, char_id, 57, 50) end)

      assert entity(s, char_id).bank_npc_id == nil
      assert_effect(s, :send, to: char_id, packet: :console_msg)
      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end

    test "dead player: rejected with :dead, no effects" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(
          char_id,
          banker_entity(char_id, bank_npc_id: nil, dead: true, hp: 0, max_hp: 100)
        )
        |> with_banker()
        |> open_session(char_id)

      assert entity(s, char_id).bank_npc_id == nil
      refute_effect(s, :send, to: char_id, packet: :bank_init)
      refute_effect(s, :send, to: char_id, packet: :console_msg)
    end

    test "meditating player: rejected with :meditating" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil, meditating: true))
        |> with_banker()
        |> open_session(char_id)

      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end

    test "navigating (sailing) player: rejected with :navigating" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil, navigating: true))
        |> with_banker()
        |> open_session(char_id)

      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end

    test "paralyzed player: rejected with :paralyzed" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil, paralyzed: true))
        |> with_banker()
        |> open_session(char_id)

      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end

    test "trading player: rejected with :already_trading" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(
          char_id,
          banker_entity(char_id, bank_npc_id: nil, trade_partner_id: 9_999)
        )
        |> with_banker()
        |> open_session(char_id)

      refute_effect(s, :send, to: char_id, packet: :bank_init)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # handle_bank_deposit_gold/3
  # VB6: modBanco.bas — HandleBankDepositGold.
  # ════════════════════════════════════════════════════════════════════

  describe "handle_bank_deposit_gold" do
    test "happy path: gold moves from purse to bank, both update packets emitted" do
      char_id = create_character!()
      set_bank_gold!(char_id, 0)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 1_000, bank_gold: 0))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit_gold(state, char_id, 400) end)

      e = entity(s, char_id)
      assert e.gold == 600
      assert e.bank_gold == 400
      assert_effect(s, :send, to: char_id, packet: :update_gold)
      assert_effect(s, :send, to: char_id, packet: :update_bank_gold)

      # Byte-level fixture: the encoded fields must carry the post-deposit
      # purse/bank balances, not just the right packet IDs.
      # eUpdateGold (28) — Gold(Int32) + OroPorNivelBilletera(Int32).
      assert <<28::little-signed-16, 600::little-signed-32, 0::little-signed-32>> =
               assert_payload(s, :send, to: char_id, packet: :update_gold)

      # eUpdateBankGld (175) — bank_gold(Int32).
      assert <<175::little-signed-16, 400::little-signed-32>> =
               assert_payload(s, :send, to: char_id, packet: :update_bank_gold)
    end

    test "deposit equal to current gold: drains purse, deposit succeeds" do
      char_id = create_character!()
      set_bank_gold!(char_id, 0)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 250, bank_gold: 0))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit_gold(state, char_id, 250) end)

      e = entity(s, char_id)
      assert e.gold == 0
      assert e.bank_gold == 250
    end

    test "amount == 0: rejected, no state change, no packets" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 1_000, bank_gold: 0))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit_gold(state, char_id, 0) end)

      e = entity(s, char_id)
      assert e.gold == 1_000
      assert e.bank_gold == 0
      refute_effect(s, :send, to: char_id, packet: :update_gold)
      refute_effect(s, :send, to: char_id, packet: :update_bank_gold)
    end

    test "negative amount: rejected" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 1_000, bank_gold: 0))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit_gold(state, char_id, -50) end)

      assert entity(s, char_id).gold == 1_000
      assert entity(s, char_id).bank_gold == 0
      refute_effect(s, :send, to: char_id, packet: :update_gold)
    end

    test "insufficient gold: rejected, no state change" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 100, bank_gold: 0))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit_gold(state, char_id, 500) end)

      e = entity(s, char_id)
      assert e.gold == 100
      assert e.bank_gold == 0
      refute_effect(s, :send, to: char_id, packet: :update_gold)
    end

    test "no bank session: rejected with :no_bank" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil, gold: 1_000))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit_gold(state, char_id, 100) end)

      assert entity(s, char_id).gold == 1_000
      refute_effect(s, :send, to: char_id, packet: :update_gold)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # handle_bank_extract_gold/3
  # VB6: modBanco.bas — HandleBankExtractGold.
  # ════════════════════════════════════════════════════════════════════

  describe "handle_bank_extract_gold" do
    test "happy path: gold moves from bank to purse, both update packets emitted" do
      char_id = create_character!()
      set_bank_gold!(char_id, 1_000)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 200, bank_gold: 1_000))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_gold(state, char_id, 300) end)

      e = entity(s, char_id)
      assert e.gold == 500
      assert e.bank_gold == 700
      assert_effect(s, :send, to: char_id, packet: :update_gold)
      assert_effect(s, :send, to: char_id, packet: :update_bank_gold)
    end

    test "amount == 0: rejected, no state change" do
      char_id = create_character!()
      set_bank_gold!(char_id, 1_000)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 0, bank_gold: 1_000))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_gold(state, char_id, 0) end)

      e = entity(s, char_id)
      assert e.gold == 0
      assert e.bank_gold == 1_000
      refute_effect(s, :send, to: char_id, packet: :update_gold)
    end

    test "negative amount: rejected" do
      char_id = create_character!()
      set_bank_gold!(char_id, 1_000)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 0, bank_gold: 1_000))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_gold(state, char_id, -1) end)

      assert entity(s, char_id).gold == 0
      assert entity(s, char_id).bank_gold == 1_000
    end

    test "insufficient bank balance: rejected, no state change" do
      char_id = create_character!()
      set_bank_gold!(char_id, 50)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, gold: 0, bank_gold: 50))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_gold(state, char_id, 100) end)

      e = entity(s, char_id)
      assert e.gold == 0
      assert e.bank_gold == 50
      refute_effect(s, :send, to: char_id, packet: :update_gold)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # handle_bank_deposit/4 (item)
  # VB6: modBanco.bas:201..261 — HandleBankDeposit.
  #
  # Note: the public arity is /5 — `(state, char_id, slot, amount,
  # slot_destino)`. Passing slot_destino == 0 selects auto-search for an
  # existing matching stack or first empty bank slot.
  # ════════════════════════════════════════════════════════════════════

  describe "handle_bank_deposit (item)" do
    test "happy path: stackable item, auto-slot — moves to bank, inventory shrinks" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @stackable_item_id,
          amount: 10,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 4, 0) end)

      e = entity(s, char_id)
      assert Enum.at(e.inventory, 0).amount == 6
      bank = BankItems.get_bank(char_id)
      assert Enum.find(bank, &(&1.slot == 1)).amount == 4
      assert_effect(s, :send, to: char_id, packet: :change_inventory_slot)
      assert_effect(s, :send, to: char_id, packet: :change_bank_slot)

      # Byte-level fixture: eChangeBankSlot (65) — slot(Int8) + obj_index(Int16)
      #   + elemental_tags(Int32) + amount(Int16) + valor(Int32) + puede_usar(Int8).
      # Pin the key fields the deposit computes (target bank slot 1, the
      # stackable obj id, no element tags, the resulting stack of 4); valor
      # and puede_usar are item/class-derived so we only bind them.
      assert <<65::little-signed-16, 1, obj_index::little-signed-16, 0::little-signed-32,
               4::little-signed-16, _valor::little-signed-32, _puede_usar>> =
               assert_payload(s, :send, to: char_id, packet: :change_bank_slot)

      assert obj_index == @stackable_item_id
    end

    test "deposit full stack: inventory slot cleared" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @stackable_item_id,
          amount: 10,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 10, 0) end)

      assert Enum.at(entity(s, char_id).inventory, 0) == nil
      bank = BankItems.get_bank(char_id)
      assert Enum.find(bank, &(&1.slot == 1)).amount == 10
    end

    test "amount <= 0: rejected with :invalid_amount, no state change" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @stackable_item_id,
          amount: 10,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 0, 0) end)

      assert Enum.at(entity(s, char_id).inventory, 0).amount == 10
      assert BankItems.get_bank(char_id) == []
      refute_effect(s, :send, to: char_id, packet: :change_bank_slot)
    end

    test "empty inventory slot: rejected with :empty_slot" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 5, 0) end)

      assert BankItems.get_bank(char_id) == []
      refute_effect(s, :send, to: char_id, packet: :change_bank_slot)
    end

    test "amount > inventory stack: rejected with :not_enough" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @stackable_item_id,
          amount: 3,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 5, 0) end)

      assert Enum.at(entity(s, char_id).inventory, 0).amount == 3
      assert BankItems.get_bank(char_id) == []
    end

    test "untradeable (instransferible) item: rejected, console_msg sent" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @untradeable_item_id,
          amount: 1,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 1, 0) end)

      assert Enum.at(entity(s, char_id).inventory, 0).amount == 1
      assert BankItems.get_bank(char_id) == []
      assert_effect(s, :send, to: char_id, packet: :console_msg)
    end

    test "gold item (id 12) blocked: returns :use_gold_deposit, no state change" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{item_id: 12, amount: 100, equipped: false, elemental_tags: 0})

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 50, 0) end)

      assert Enum.at(entity(s, char_id).inventory, 0).amount == 100
      assert BankItems.get_bank(char_id) == []
    end

    test "all 40 bank slots full to max stack: deposit rejected with :stack_full" do
      char_id = create_character!()

      for slot <- 1..@bank_max_slots do
        seed_bank_item!(char_id, slot, @stackable_item_id, 10_000)
      end

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @stackable_item_id,
          amount: 5,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 5, 0) end)

      # Inventory untouched, slot 1 still at the original 10_000 cap.
      assert Enum.at(entity(s, char_id).inventory, 0).amount == 5
      bank = BankItems.get_bank(char_id)
      assert Enum.find(bank, &(&1.slot == 1)).amount == 10_000
      assert_effect(s, :send, to: char_id, packet: :console_msg)
      refute_effect(s, :send, to: char_id, packet: :change_bank_slot)
    end

    test "no bank session: rejected with :no_bank" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @stackable_item_id,
          amount: 5,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_deposit(state, char_id, 1, 5, 0) end)

      assert Enum.at(entity(s, char_id).inventory, 0).amount == 5
      assert BankItems.get_bank(char_id) == []
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # handle_bank_extract_item/5
  # VB6: modBanco.bas:94..  — HandleBankExtractItem.
  # ════════════════════════════════════════════════════════════════════

  describe "handle_bank_extract_item" do
    test "happy path: bank stack moves to inventory; bank/inv packets emitted" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @stackable_item_id, 20)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 1, 8, 0) end)

      e = entity(s, char_id)
      first_filled = Enum.find(e.inventory, &match?(%{item_id: @stackable_item_id}, &1))
      assert first_filled.amount == 8

      bank = BankItems.get_bank(char_id)
      assert Enum.find(bank, &(&1.slot == 1)).amount == 12
      assert_effect(s, :send, to: char_id, packet: :change_bank_slot)
      assert_effect(s, :send, to: char_id, packet: :change_inventory_slot)
    end

    test "withdraw entire stack: bank slot cleared (deleted row)" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @stackable_item_id, 5)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 1, 5, 0) end)

      e = entity(s, char_id)
      first_filled = Enum.find(e.inventory, &match?(%{item_id: @stackable_item_id}, &1))
      assert first_filled.amount == 5

      assert BankItems.get_bank(char_id) == []
      assert_effect(s, :send, to: char_id, packet: :change_bank_slot)
    end

    test "amount <= 0: rejected with :invalid_amount" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @stackable_item_id, 5)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 1, 0, 0) end)

      assert Enum.find(BankItems.get_bank(char_id), &(&1.slot == 1)).amount == 5
      assert Enum.all?(entity(s, char_id).inventory, &is_nil/1)
    end

    test "empty bank slot: rejected with :empty_bank_slot" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 5, 1, 0) end)

      assert Enum.all?(entity(s, char_id).inventory, &is_nil/1)
    end

    test "amount > bank stack: rejected with :not_enough" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @stackable_item_id, 3)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 1, 5, 0) end)

      assert Enum.find(BankItems.get_bank(char_id), &(&1.slot == 1)).amount == 3
      assert Enum.all?(entity(s, char_id).inventory, &is_nil/1)
    end

    test "inventory full (non-stackable item): rolls back DB withdraw" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @nonstackable_item_id, 1)

      # Fill all 24 inventory slots with a different non-stackable item
      # so add_item can't find a free slot.
      filler = %{item_id: @nonstackable_item_id, amount: 1, equipped: false, elemental_tags: 0}
      inv = List.duplicate(filler, 24)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, inventory: inv))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 1, 1, 0) end)

      # Inventory unchanged, console error sent, bank slot still has 1
      # (rollback from `do_extract_item`'s :inventory_full branch).
      assert length(entity(s, char_id).inventory) == 24
      assert Enum.all?(entity(s, char_id).inventory, &(&1.item_id == @nonstackable_item_id))
      bank_after = BankItems.get_bank(char_id)
      assert Enum.find(bank_after, &(&1.slot == 1)).amount == 1
      assert_effect(s, :send, to: char_id, packet: :console_msg)
    end

    test "no bank session: rejected with :no_bank" do
      char_id = create_character!()
      seed_bank_item!(char_id, 1, @stackable_item_id, 5)

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_extract_item(state, char_id, 1, 1, 0) end)

      assert Enum.all?(entity(s, char_id).inventory, &is_nil/1)
      assert Enum.find(BankItems.get_bank(char_id), &(&1.slot == 1)).amount == 5
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # handle_bank_end/2
  # VB6: modBanco.bas — HandleBankEnd.
  # ════════════════════════════════════════════════════════════════════

  describe "handle_bank_end" do
    test "clears bank_npc_id, emits :bank_end" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: :bank1))
        |> with_banker()
        |> run_bank(fn state -> Bank.handle_bank_end(state, char_id) end)

      assert entity(s, char_id).bank_npc_id == nil
      assert_effect(s, :send, to: char_id, packet: :bank_end)

      # Byte-level fixture: eBankEnd (9) is a pure signal — the payload must be
      # exactly the 2-byte packet id with no trailing bytes.
      assert <<9::little-signed-16>> == assert_payload(s, :send, to: char_id, packet: :bank_end)
    end

    test "idempotent: calling without an active session still clears + emits :bank_end" do
      char_id = create_character!()

      s =
        new(map_id: 1)
        |> with_player(char_id, banker_entity(char_id, bank_npc_id: nil))
        |> run_bank(fn state -> Bank.handle_bank_end(state, char_id) end)

      assert entity(s, char_id).bank_npc_id == nil
      assert_effect(s, :send, to: char_id, packet: :bank_end)
    end
  end
end
