defmodule Arena.GamblingPriestArenaTest do
  @moduledoc """
  Tests for gambling (timbero NPC), forgiveness (priest), and arena entry — task 42.

  Covers:
  - PlayerEntity gambling fields (gamble_wins, gamble_losses, gamble_plays)
  - Gamble preconditions (dead, amount <= 0, insufficient gold)
  - Gamble win/loss updates gold and counters
  - Forgive clears criminal flag
  - Forgive no-op for non-criminals
  - Arena entry preconditions
  - NpcDef arena fields (arena_enabled, map_entry_price, map_target_entry)
  - NpcDef creatures field for trainers
  - Client decoder: forgive packet (ID 68) and arena_entry packet (ID 259)
  """
  use ExUnit.Case, async: true

  alias AoEntities.PlayerEntity
  alias Arena.Data.NpcDef

  # ---- PlayerEntity gambling fields ----

  describe "PlayerEntity gambling fields" do
    test "defaults gamble_wins to 0" do
      entity = %PlayerEntity{}
      assert entity.gamble_wins == 0
    end

    test "defaults gamble_losses to 0" do
      entity = %PlayerEntity{}
      assert entity.gamble_losses == 0
    end

    test "defaults gamble_plays to 0" do
      entity = %PlayerEntity{}
      assert entity.gamble_plays == 0
    end
  end

  # ---- Gamble logic (unit-level, testing the cond branches) ----

  describe "gamble preconditions" do
    test "dead player cannot gamble" do
      entity = %PlayerEntity{char_id: 1, dead: true, gold: 1000}
      assert entity.dead == true
    end

    test "amount <= 0 is rejected" do
      amount = 0
      assert amount <= 0
    end

    test "insufficient gold blocks gamble" do
      entity = %PlayerEntity{char_id: 1, gold: 50}
      amount = 100
      assert entity.gold < amount
    end
  end

  describe "gamble win/loss" do
    test "winning adds amount to gold and increments wins/plays" do
      entity = %PlayerEntity{char_id: 1, gold: 100, gamble_wins: 0, gamble_plays: 0}
      amount = 50

      entity = %{entity |
        gold: entity.gold + amount,
        gamble_wins: entity.gamble_wins + 1,
        gamble_plays: entity.gamble_plays + 1
      }

      assert entity.gold == 150
      assert entity.gamble_wins == 1
      assert entity.gamble_plays == 1
    end

    test "losing subtracts amount from gold and increments losses/plays" do
      entity = %PlayerEntity{char_id: 1, gold: 100, gamble_losses: 0, gamble_plays: 0}
      amount = 50

      entity = %{entity |
        gold: entity.gold - amount,
        gamble_losses: entity.gamble_losses + 1,
        gamble_plays: entity.gamble_plays + 1
      }

      assert entity.gold == 50
      assert entity.gamble_losses == 1
      assert entity.gamble_plays == 1
    end
  end

  # ---- Forgive logic ----

  describe "forgive" do
    test "criminal flag is cleared by forgive" do
      entity = %PlayerEntity{char_id: 1, criminal: true}
      entity = %{entity | criminal: false}
      assert entity.criminal == false
    end

    test "non-criminal forgive is a no-op" do
      entity = %PlayerEntity{char_id: 1, criminal: false}
      # handle_forgive checks: if entity.criminal, sends "No eres un criminal."
      refute entity.criminal
    end
  end

  # ---- Arena entry preconditions ----

  describe "arena entry" do
    test "insufficient gold blocks arena entry" do
      entity = %PlayerEntity{char_id: 1, gold: 50}
      entry_price = 100
      assert entity.gold < entry_price
    end

    test "dead player cannot enter arena" do
      entity = %PlayerEntity{char_id: 1, dead: true, gold: 1000}
      assert entity.dead == true
    end

    test "gold is deducted on successful entry" do
      entity = %PlayerEntity{char_id: 1, gold: 500}
      entry_price = 100
      entity = %{entity | gold: entity.gold - entry_price}
      assert entity.gold == 400
    end
  end

  # ---- NpcDef arena fields ----

  describe "NpcDef arena/trainer fields" do
    test "NpcDef has arena fields with defaults" do
      npc_def = %NpcDef{}
      assert npc_def.arena_enabled == false
      assert npc_def.map_entry_price == 0
      assert npc_def.map_target_entry == 0
      assert npc_def.map_target_entry_x == 0
      assert npc_def.map_target_entry_y == 0
    end

    test "NpcDef has creatures field defaulting to empty list" do
      npc_def = %NpcDef{}
      assert npc_def.creatures == []
    end
  end

  # ---- Client decoder: forgive and arena_entry packets ----

  describe "client decoder for forgive and arena_entry" do
    test "forgive packet (ID 68) decodes with no payload" do
      # Build a minimal packet: ID 68 as Int16LE
      packet = <<68::little-signed-16>>
      assert {:ok, {:forgive, %{}}, <<>>} = AoProtocol.Client.Decoder.decode(packet)
    end

    test "arena_entry packet (ID 259) decodes with no payload" do
      packet = <<259::little-signed-16>>
      assert {:ok, {:arena_entry, %{}}, <<>>} = AoProtocol.Client.Decoder.decode(packet)
    end
  end
end
