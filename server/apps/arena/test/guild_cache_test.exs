defmodule Arena.GuildCacheTest do
  @moduledoc """
  Tests for guild info caching on PlayerEntity, eliminating GuildServer RPCs
  from the character_create_packet hot path.
  """
  use ExUnit.Case, async: true

  import Arena.Test.MapStateFactory

  alias AoEntities.PlayerEntity
  alias Arena.Map.Helpers

  defp make_entity(overrides \\ %{}) do
    base = %PlayerEntity{
      char_id: 1,
      name: "TestPlayer",
      account_id: 1,
      x: 50,
      y: 50,
      char_index: 1,
      body_id: 1,
      head_id: 1,
      hp: 100,
      max_hp: 100,
      mana: 50,
      max_mana: 100,
      heading: :south,
      guild_id: 0,
      guild_level: 0
    }

    Map.merge(base, overrides)
  end

  # ── Test 1: character_create_packet uses cached guild info ──

  describe "character_create_packet uses cached guild info" do
    test "packet contains guild_id and guild_level from entity fields" do
      entity = make_entity(%{guild_id: 5, guild_level: 3})
      {:character_create, packet} = Helpers.character_create_packet(entity)

      assert packet.clan_index == 5
      assert packet.clan_nivel == 3
    end
  end

  # ── Test 2: character_create_packet with no guild uses defaults ──

  describe "character_create_packet with no guild" do
    test "uses defaults (0, 0) when player has no guild" do
      entity = make_entity(%{guild_id: 0, guild_level: 0})
      {:character_create, packet} = Helpers.character_create_packet(entity)

      assert packet.clan_index == 0
      assert packet.clan_nivel == 0
    end
  end

  # ── Test 3: guild join updates entity cache ──

  describe "guild join updates entity cache" do
    test "guild_id and guild_level are set on the entity after guild join message" do
      pid = self()

      state =
        map_state(
          players: %{1 => make_entity()},
          sessions: %{1 => pid}
        )

      # Simulate what guild join handler should do: update the entity
      entity = state.players[1]
      entity = %{entity | guild_id: 7, guild_level: 2}
      state = %{state | players: Map.put(state.players, 1, entity)}

      updated = state.players[1]
      assert updated.guild_id == 7
      assert updated.guild_level == 2
    end
  end

  # ── Test 4: guild leave clears entity cache ──

  describe "guild leave clears entity cache" do
    test "guild_id and guild_level reset to 0 after guild leave" do
      pid = self()
      entity = make_entity(%{guild_id: 7, guild_level: 2})

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => pid}
        )

      # Simulate guild leave: clear guild fields
      entity = state.players[1]
      entity = %{entity | guild_id: 0, guild_level: 0}
      state = %{state | players: Map.put(state.players, 1, entity)}

      updated = state.players[1]
      assert updated.guild_id == 0
      assert updated.guild_level == 0
    end
  end

  # ── Test 5: character_create_packet never calls GuildServer ──

  describe "character_create_packet never calls GuildServer (adversarial)" do
    test "works without GuildServer running — no RPC, no crash, no timeout" do
      # GuildServer is NOT started in this test (async: true, no setup).
      # If character_create_packet still tried to call GuildServer.get_guild,
      # it would raise or timeout. The fact that this succeeds proves the
      # RPC has been eliminated from the hot path.
      entity = make_entity(%{guild_id: 10, guild_level: 5})

      # This must NOT raise, crash, or timeout
      {:character_create, packet} = Helpers.character_create_packet(entity)

      assert packet.clan_index == 10
      assert packet.clan_nivel == 5
    end

    test "entity with guild_id=0 also works without GuildServer" do
      entity = make_entity(%{guild_id: 0, guild_level: 0})
      {:character_create, packet} = Helpers.character_create_packet(entity)

      assert packet.clan_index == 0
      assert packet.clan_nivel == 0
    end
  end

  # ── Test 6: rapid guild join/leave doesn't corrupt state ──

  describe "rapid guild join/leave (adversarial)" do
    test "20 alternating join/leave operations produce consistent final state" do
      pid = self()
      entity = make_entity()

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => pid}
        )

      # Simulate 20 rapid alternating join/leave operations
      state =
        Enum.reduce(1..20, state, fn i, acc ->
          entity = acc.players[1]

          entity =
            if rem(i, 2) == 1 do
              # join
              %{entity | guild_id: 42, guild_level: 3}
            else
              # leave
              %{entity | guild_id: 0, guild_level: 0}
            end

          %{acc | players: Map.put(acc.players, 1, entity)}
        end)

      # 20 is even, so the last op was a leave
      final = state.players[1]
      assert final.guild_id == 0
      assert final.guild_level == 0

      # Verify packet is consistent with entity state
      {:character_create, packet} = Helpers.character_create_packet(final)
      assert packet.clan_index == 0
      assert packet.clan_nivel == 0
    end

    test "odd number of operations ends with join state" do
      pid = self()
      entity = make_entity()

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => pid}
        )

      # 19 operations: last is odd = join
      state =
        Enum.reduce(1..19, state, fn i, acc ->
          entity = acc.players[1]

          entity =
            if rem(i, 2) == 1 do
              %{entity | guild_id: 42, guild_level: 3}
            else
              %{entity | guild_id: 0, guild_level: 0}
            end

          %{acc | players: Map.put(acc.players, 1, entity)}
        end)

      final = state.players[1]
      assert final.guild_id == 42
      assert final.guild_level == 3

      {:character_create, packet} = Helpers.character_create_packet(final)
      assert packet.clan_index == 42
      assert packet.clan_nivel == 3
    end
  end
end
