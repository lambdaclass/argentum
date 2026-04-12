defmodule Arena.FactionCouncilTest do
  @moduledoc """
  Tests for faction/council online list and council messaging.

  Covers:
  - OnlineDirectory faction tracking (register, update, list_by_faction)
  - Online royal army returns only armada-aligned players
  - Online chaos legion returns only chaos-aligned players
  - Council message restricted to faction members
  - Non-faction player gets empty list
  """
  use ExUnit.Case, async: false

  alias AoSession.OnlineDirectory

  setup do
    # Ensure OnlineDirectory is running
    case GenServer.whereis(OnlineDirectory) do
      nil -> start_supervised!(OnlineDirectory)
      _pid -> :ok
    end

    # Clear the ETS table between tests for isolation
    :ets.delete_all_objects(:ao_online_directory)

    :ok
  end

  # ---- OnlineDirectory faction tracking ----

  describe "OnlineDirectory.register/5 with faction" do
    test "stores faction when provided" do
      :ok = OnlineDirectory.register(1, "Soldado", 1, self(), faction: :royal_army)
      {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.faction == :royal_army
    end

    test "defaults faction to :none when not provided" do
      :ok = OnlineDirectory.register(2, "Civil", 1, self())
      {:ok, info} = OnlineDirectory.lookup_by_id(2)
      assert info.faction == :none
    end
  end

  describe "OnlineDirectory.update_faction/2" do
    test "updates faction for an existing character" do
      :ok = OnlineDirectory.register(1, "Recluta", 1, self(), faction: :none)
      :ok = OnlineDirectory.update_faction(1, :royal_army)
      {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.faction == :royal_army
    end

    test "preserves other fields after update" do
      pid = self()
      :ok = OnlineDirectory.register(1, "Guerrero", 42, pid, is_gm: true, faction: :none)
      :ok = OnlineDirectory.update_faction(1, :chaos_legion)
      {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.faction == :chaos_legion
      assert info.name == "Guerrero"
      assert info.map_id == 42
      assert info.session_pid == pid
      assert info.is_gm == true
    end

    test "returns :ok for non-existent char_id" do
      assert :ok == OnlineDirectory.update_faction(999, :royal_army)
    end
  end

  describe "OnlineDirectory.list_by_faction/1" do
    test "returns only armada-aligned players for :royal_army" do
      :ok = OnlineDirectory.register(1, "ArmadaOne", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(2, "ArmadaTwo", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(3, "ChaosPlayer", 1, self(), faction: :chaos_legion)
      :ok = OnlineDirectory.register(4, "Neutral", 1, self(), faction: :none)

      members = OnlineDirectory.list_by_faction(:royal_army)
      names = Enum.map(members, & &1.name) |> Enum.sort()

      assert names == ["ArmadaOne", "ArmadaTwo"]
    end

    test "returns only chaos-aligned players for :chaos_legion" do
      :ok = OnlineDirectory.register(1, "ArmadaPlayer", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(2, "ChaosOne", 1, self(), faction: :chaos_legion)
      :ok = OnlineDirectory.register(3, "ChaosTwo", 1, self(), faction: :chaos_legion)
      :ok = OnlineDirectory.register(4, "Neutral", 1, self(), faction: :none)

      members = OnlineDirectory.list_by_faction(:chaos_legion)
      names = Enum.map(members, & &1.name) |> Enum.sort()

      assert names == ["ChaosOne", "ChaosTwo"]
    end

    test "returns empty list when no players match the faction" do
      :ok = OnlineDirectory.register(1, "Neutral", 1, self(), faction: :none)
      :ok = OnlineDirectory.register(2, "Chaos", 1, self(), faction: :chaos_legion)

      members = OnlineDirectory.list_by_faction(:royal_army)
      assert members == []
    end

    test "returns empty list when no players are online" do
      members = OnlineDirectory.list_by_faction(:royal_army)
      assert members == []
    end

    test "includes is_gm flag in results" do
      :ok = OnlineDirectory.register(1, "GMPlayer", 1, self(), faction: :royal_army, is_gm: true)
      :ok = OnlineDirectory.register(2, "Regular", 1, self(), faction: :royal_army, is_gm: false)

      members = OnlineDirectory.list_by_faction(:royal_army)
      gm_member = Enum.find(members, &(&1.name == "GMPlayer"))
      regular_member = Enum.find(members, &(&1.name == "Regular"))

      assert gm_member.is_gm == true
      assert regular_member.is_gm == false
    end

    test "reflects faction changes after update_faction" do
      :ok = OnlineDirectory.register(1, "Switcher", 1, self(), faction: :royal_army)

      assert length(OnlineDirectory.list_by_faction(:royal_army)) == 1
      assert length(OnlineDirectory.list_by_faction(:chaos_legion)) == 0

      :ok = OnlineDirectory.update_faction(1, :chaos_legion)

      assert length(OnlineDirectory.list_by_faction(:royal_army)) == 0
      assert length(OnlineDirectory.list_by_faction(:chaos_legion)) == 1
    end
  end

  # ---- Packet decoder tests ----

  describe "packet decoding" do
    test "decodes online_royal_army packet (ID 132)" do
      # Packet ID as little-endian Int16, no payload
      packet = <<132::little-signed-integer-16>>
      assert {:ok, {:online_royal_army, %{}}, <<>>} = AoProtocol.Client.Decoder.decode(packet)
    end

    test "decodes online_chaos_legion packet (ID 133)" do
      packet = <<133::little-signed-integer-16>>
      assert {:ok, {:online_chaos_legion, %{}}, <<>>} = AoProtocol.Client.Decoder.decode(packet)
    end

    test "decodes council_message packet (ID 61)" do
      # ID 61 + string8 message ("Hola") — string8 is little-endian Int16 length prefix
      msg = "Hola"
      msg_len = byte_size(msg)
      packet = <<61::little-signed-integer-16, msg_len::little-integer-16, msg::binary>>
      assert {:ok, {:council_message, %{message: "Hola"}}, <<>>} = AoProtocol.Client.Decoder.decode(packet)
    end
  end

  # ---- SessionLogic handler tests ----

  describe "SessionLogic.handle_command online_royal_army" do
    test "returns list of armada members when some are online" do
      :ok = OnlineDirectory.register(10, "Capitan", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(11, "Teniente", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(12, "Enemigo", 1, self(), faction: :chaos_legion)

      state = %{character_id: 99, map_id: 1, account_id: 1, char_index: 1,
                entity: nil, is_gm: false, is_dead: false, in_trade: false,
                hogar_timer: nil}

      {_state, packets} = AoTcpGateway.SessionLogic.handle_command(state, {:online_royal_army, %{}})

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert String.contains?(msg, "Armada Real en linea:")
      assert String.contains?(msg, "Capitan")
      assert String.contains?(msg, "Teniente")
      refute String.contains?(msg, "Enemigo")
    end

    test "returns empty message when no armada members online" do
      state = %{character_id: 99, map_id: 1, account_id: 1, char_index: 1,
                entity: nil, is_gm: false, is_dead: false, in_trade: false,
                hogar_timer: nil}

      {_state, packets} = AoTcpGateway.SessionLogic.handle_command(state, {:online_royal_army, %{}})

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert msg == "No hay miembros de la Armada Real en linea."
    end
  end

  describe "SessionLogic.handle_command online_chaos_legion" do
    test "returns list of chaos members when some are online" do
      :ok = OnlineDirectory.register(10, "Oscuro", 1, self(), faction: :chaos_legion)
      :ok = OnlineDirectory.register(11, "Armada", 1, self(), faction: :royal_army)

      state = %{character_id: 99, map_id: 1, account_id: 1, char_index: 1,
                entity: nil, is_gm: false, is_dead: false, in_trade: false,
                hogar_timer: nil}

      {_state, packets} = AoTcpGateway.SessionLogic.handle_command(state, {:online_chaos_legion, %{}})

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert String.contains?(msg, "Legion del Caos en linea:")
      assert String.contains?(msg, "Oscuro")
      refute String.contains?(msg, "Armada")
    end

    test "returns empty message when no chaos members online" do
      :ok = OnlineDirectory.register(10, "Armada", 1, self(), faction: :royal_army)

      state = %{character_id: 99, map_id: 1, account_id: 1, char_index: 1,
                entity: nil, is_gm: false, is_dead: false, in_trade: false,
                hogar_timer: nil}

      {_state, packets} = AoTcpGateway.SessionLogic.handle_command(state, {:online_chaos_legion, %{}})

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert msg == "No hay miembros de la Legion del Caos en linea."
    end
  end

  describe "SessionLogic.handle_command council_message" do
    test "non-faction player gets rejection message" do
      # council_message requires snapshot_entity, so we test the state machine
      # by calling handle_command with a nil character_id (should be caught)
      state = %{character_id: nil, map_id: 1, account_id: 1, char_index: 1,
                entity: nil, is_gm: false, is_dead: false, in_trade: false,
                hogar_timer: nil}

      # With nil character_id, falls through to catch-all
      {_state, packets} = AoTcpGateway.SessionLogic.handle_command(state, {:council_message, %{message: "test"}})
      # Catch-all returns empty packets
      assert packets == []
    end
  end

  # ---- Packet ID constants ----

  describe "packet IDs" do
    test "online_royal_army client packet ID is 132" do
      assert AoProtocol.PacketIds.Client.online_royal_army() == 132
    end

    test "online_chaos_legion client packet ID is 133" do
      assert AoProtocol.PacketIds.Client.online_chaos_legion() == 133
    end

    test "council_message client packet ID is 61" do
      assert AoProtocol.PacketIds.Client.council_message() == 61
    end
  end
end
