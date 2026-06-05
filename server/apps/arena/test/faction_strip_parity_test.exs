defmodule Arena.FactionStripParityTest do
  @moduledoc """
  Pins VB6 parity for faction-exclusive item stripping on faction
  transitions (Phase 1 / Item 1 of `ROADMAP.md`).

  VB6 anchors:
    * `ModFacciones.bas:144` — ExpulsarFaccionReal (leave path).
    * `ModFacciones.bas:155` — ExpulsarFaccionCaos (leave path).
    * `ModFacciones.bas:357` — PerderItemsFaccionarios (strip helper —
      walks user inventory AND bank, clearing every slot whose
      ObjData(.).Real / .Caos is set).
    * `Modulo_UsUaRiOs.bas:2260` — VolverCriminal (Royal Army member
      becoming criminal is also expelled and stripped).

  Items are seeded directly into the GameData ETS table so the test is
  hermetic. Faction-strip semantics:

    * Inventory slot is cleared (not merely unequipped).
    * Equipment mapping for the corresponding slot is reset.
    * Armor strip also restores `base_body_id`.
    * Bank rows for Real / Caos items are deleted from the DB.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, ItemDef, NpcDef}
  alias Arena.Map.{CriminalStatus, Faction}
  alias GameBackend.BankItems

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  # Synthetic ids far above the shipped obj.dat range so we never
  # collide with a real definition.
  @royal_armor_id 96_001
  @royal_helmet_id 96_002
  @caos_armor_id 96_010
  @neutral_apple_id 96_020
  @royal_npc_id 96_900

  @npc_type_enlistador 5

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Arena.Settings.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case GenServer.whereis(AoSession.OnlineDirectory) do
      nil -> start_supervised!(AoSession.OnlineDirectory)
      _pid -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    seed_item(@royal_armor_id, %{
      name: "Armadura Real",
      obj_type: 3,
      equip_slot: :armor,
      real: true,
      caos: false,
      ropaje: %{humano_m: 250}
    })

    seed_item(@royal_helmet_id, %{
      name: "Casco Real",
      obj_type: 17,
      equip_slot: :helmet,
      real: true,
      caos: false
    })

    seed_item(@caos_armor_id, %{
      name: "Uniforme del Caos",
      obj_type: 3,
      equip_slot: :armor,
      real: false,
      caos: true
    })

    seed_item(@neutral_apple_id, %{
      name: "Manzana",
      obj_type: 1,
      stackable: true,
      max_hit: 10_000,
      real: false,
      caos: false
    })

    :ets.insert(:arena_game_data, {{:npc, @royal_npc_id}, enlistador_def(@royal_npc_id, 3)})

    # Faction ranks: minimum so the player can stand at rank 1.
    :ets.insert(
      :arena_game_data,
      {{:faction_ranks, :royal_army},
       [
         %{rank: 1, required_level: 1, required_score: 0, title: "Soldado"}
       ]}
    )

    :ets.insert(:arena_game_data, {{:faction_rewards, :royal_army}, []})
    :ets.delete_all_objects(:ao_online_directory)
    :ok
  end

  defp seed_item(id, fields) do
    item =
      %ItemDef{id: id}
      |> Map.merge(Map.new(fields))

    :ets.insert(:arena_game_data, {{:item, id}, item})
  end

  defp enlistador_def(id, faccion) do
    %NpcDef{
      id: id,
      npc_type: @npc_type_enlistador,
      name: "Enlistador Real",
      faccion: faccion,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  defp with_royal_enlistador(scenario) do
    with_npc(scenario, :enl_royal, npc_id: @royal_npc_id, x: 51, y: 50)
  end

  defp create_character! do
    {:ok, account} =
      GameBackend.Account.create(
        "factstrip_acc_#{:erlang.unique_integer([:positive])}",
        "password123"
      )

    {:ok, char} =
      GameBackend.Characters.create(%{
        name: "factstrip_#{:erlang.unique_integer([:positive])}",
        account_id: account.id
      })

    char.id
  end

  defp royal_recruit(opts) do
    Keyword.merge(
      [
        level: 30,
        faction: :royal_army,
        faction_rank_armada: 1,
        faction_rank_chaos: 0,
        faction_score: 0,
        faction_reenlistadas: 0,
        criminal: false,
        citizens_killed: 0,
        class: :guerrero,
        gold: 0,
        body_id: 5,
        base_body_id: 1,
        equipment: %{
          weapon: nil,
          armor: nil,
          shield: nil,
          helmet: nil,
          ring: nil,
          municion: nil,
          saddle: nil
        }
      ],
      opts
    )
  end

  # ────────────────────────────────────────────────────────────────────
  # Faction.strip_faction_items/1 — pure entity-only transform.
  # VB6: ModFacciones.bas:357 — PerderItemsFaccionarios.
  # ────────────────────────────────────────────────────────────────────

  describe "strip_faction_items/1: inventory" do
    test "removes equipped Real armor and restores base_body_id" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @royal_armor_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })

      entity = %{
        char_id: 0,
        inventory: inv,
        equipment: %{armor: @royal_armor_id},
        body_id: 250,
        base_body_id: 1
      }

      out = Faction.strip_faction_items(entity)

      assert Enum.at(out.inventory, 0) == nil, "slot must be cleared, not just unequipped"
      assert out.equipment.armor == nil
      assert out.body_id == 1, "body_id must revert to base_body_id"
    end

    test "removes Caos uniform the same way" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @caos_armor_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })

      entity = %{
        char_id: 0,
        inventory: inv,
        equipment: %{armor: @caos_armor_id},
        body_id: 300,
        base_body_id: 1
      }

      out = Faction.strip_faction_items(entity)
      assert Enum.at(out.inventory, 0) == nil
      assert out.equipment.armor == nil
      assert out.body_id == 1
    end

    test "removes non-equipped Real items from inventory too" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(3, %{
          item_id: @royal_helmet_id,
          amount: 1,
          equipped: false,
          elemental_tags: 0
        })

      entity = %{
        char_id: 0,
        inventory: inv,
        equipment: %{helmet: nil},
        body_id: 1,
        base_body_id: 1
      }

      out = Faction.strip_faction_items(entity)
      assert Enum.at(out.inventory, 3) == nil
    end

    test "leaves neutral items untouched" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @neutral_apple_id,
          amount: 5,
          equipped: false,
          elemental_tags: 3
        })

      entity = %{
        char_id: 0,
        inventory: inv,
        equipment: %{},
        body_id: 1,
        base_body_id: 1
      }

      out = Faction.strip_faction_items(entity)
      slot = Enum.at(out.inventory, 0)
      assert slot.item_id == @neutral_apple_id
      assert slot.amount == 5
      # Per-instance elemental_tags must survive even when nothing was
      # stripped — this is the trade/pickup/drop preservation contract.
      assert slot.elemental_tags == 3
    end

    test "mixed inventory: Real items dropped, neutral kept, equipment slot cleared" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @royal_armor_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })
        |> List.replace_at(1, %{
          item_id: @neutral_apple_id,
          amount: 10,
          equipped: false,
          elemental_tags: 0
        })
        |> List.replace_at(5, %{
          item_id: @royal_helmet_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })

      entity = %{
        char_id: 0,
        inventory: inv,
        equipment: %{armor: @royal_armor_id, helmet: @royal_helmet_id},
        body_id: 250,
        base_body_id: 1
      }

      out = Faction.strip_faction_items(entity)
      assert Enum.at(out.inventory, 0) == nil
      assert Enum.at(out.inventory, 1).item_id == @neutral_apple_id
      assert Enum.at(out.inventory, 5) == nil
      assert out.equipment.armor == nil
      assert out.equipment.helmet == nil
      assert out.body_id == 1
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Faction.strip_bank_faction_items/1 — DB-backed bank strip.
  # ────────────────────────────────────────────────────────────────────

  describe "strip_bank_faction_items/1: bank" do
    test "removes only Real / Caos rows, keeps neutral rows" do
      char_id = create_character!()

      {:ok, _} = BankItems.upsert(char_id, 1, @royal_armor_id, 1, 0)
      {:ok, _} = BankItems.upsert(char_id, 2, @caos_armor_id, 1, 0)
      {:ok, _} = BankItems.upsert(char_id, 3, @neutral_apple_id, 25, 0)

      :ok = Faction.strip_bank_faction_items(char_id)

      remaining = BankItems.get_bank(char_id)
      slots = Enum.map(remaining, & &1.slot)

      assert 3 in slots, "neutral item must remain in bank"
      refute 1 in slots, "Real item must be removed from bank"
      refute 2 in slots, "Caos item must be removed from bank"
    end

    test "no-op for an empty bank" do
      char_id = create_character!()
      assert Faction.strip_bank_faction_items(char_id) == :ok
      assert BankItems.get_bank(char_id) == []
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_leave_faction/2 — end-to-end strip on /RENUNCIAR.
  # VB6: Protocol.bas:4820 — HandleLeaveFaction.
  # ────────────────────────────────────────────────────────────────────

  describe "handle_leave_faction/2: end-to-end strip" do
    test "strips inventory AND bank Real/Caos items, leaves neutral rows" do
      char_id = create_character!()

      {:ok, _} = BankItems.upsert(char_id, 1, @royal_armor_id, 1, 0)
      {:ok, _} = BankItems.upsert(char_id, 5, @neutral_apple_id, 50, 0)

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @royal_armor_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })
        |> List.replace_at(2, %{
          item_id: @neutral_apple_id,
          amount: 3,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(
          char_id,
          royal_recruit(inventory: inv, equipment: %{armor: @royal_armor_id}, body_id: 250)
        )
        |> with_royal_enlistador()
        |> run(fn state -> Faction.handle_leave_faction(state, char_id) end)

      e = entity(s, char_id)
      assert e.faction == :none
      assert e.faction_reenlistadas == 1
      assert Enum.at(e.inventory, 0) == nil, "royal armor must be removed"
      assert Enum.at(e.inventory, 2).item_id == @neutral_apple_id, "neutral kept"
      assert e.equipment.armor == nil
      assert e.body_id == 1, "body_id must revert"

      # Bank reflects DB-side strip.
      remaining = BankItems.get_bank(char_id)
      slots = Enum.map(remaining, & &1.slot)
      refute 1 in slots, "Real bank row removed"
      assert 5 in slots, "neutral bank row kept"

      assert_effect(s, :broadcast_character_change, char_id: char_id)
      assert_effect(s, :send, to: char_id, packet: :change_inventory_slot)
      assert_effect(s, :send, to: char_id, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # CriminalStatus.volver_criminal/3 — Royal Army member transition.
  # VB6: Modulo_UsUaRiOs.bas:2260-2296 — VolverCriminal also expels
  # Armada Real members and runs PerderItemsFaccionarios.
  # ────────────────────────────────────────────────────────────────────

  describe "volver_criminal/3: Royal Army expulsion" do
    test "ejects faction, strips Real items from inventory + bank" do
      char_id = create_character!()

      {:ok, _} = BankItems.upsert(char_id, 1, @royal_armor_id, 1, 0)

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @royal_armor_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(
          char_id,
          royal_recruit(inventory: inv, equipment: %{armor: @royal_armor_id}, body_id: 250)
        )

      {entity, _state, _effects} =
        CriminalStatus.volver_criminal(s.state, char_id, Map.fetch!(s.state.players, char_id))

      assert entity.criminal == true
      assert entity.faction == :none, "Royal Army member must be expelled"
      assert entity.faction_rank_armada == 0
      assert entity.faction_reenlistadas == 1
      assert Enum.at(entity.inventory, 0) == nil
      assert entity.equipment.armor == nil
      assert entity.body_id == 1

      remaining = BankItems.get_bank(char_id)
      assert Enum.find(remaining, &(&1.slot == 1)) == nil, "bank Real row stripped"
    end

    test "Ciudadano (faction: :none) becoming criminal does NOT touch inventory" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @neutral_apple_id,
          amount: 5,
          equipped: false,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(
          char_id,
          royal_recruit(
            faction: :none,
            faction_rank_armada: 0,
            inventory: inv,
            equipment: %{}
          )
        )

      {entity, _state, _effects} =
        CriminalStatus.volver_criminal(s.state, char_id, Map.fetch!(s.state.players, char_id))

      assert entity.criminal == true
      assert entity.faction == :none
      assert Enum.at(entity.inventory, 0).item_id == @neutral_apple_id, "neutral item kept"
    end

    test "Chaos Legion member is short-circuited (no criminal flag, no strip)" do
      char_id = create_character!()

      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{
          item_id: @caos_armor_id,
          amount: 1,
          equipped: true,
          elemental_tags: 0
        })

      s =
        new(map_id: 1)
        |> with_player(
          char_id,
          royal_recruit(
            faction: :chaos_legion,
            faction_rank_armada: 0,
            faction_rank_chaos: 1,
            criminal: true,
            inventory: inv,
            equipment: %{armor: @caos_armor_id},
            body_id: 250
          )
        )

      {entity, _state, _effects} =
        CriminalStatus.volver_criminal(s.state, char_id, Map.fetch!(s.state.players, char_id))

      # Chaos / Concilio short-circuit (VB6:2271): no state change at all.
      assert entity.faction == :chaos_legion
      assert Enum.at(entity.inventory, 0).item_id == @caos_armor_id
    end
  end
end
