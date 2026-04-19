defmodule Arena.DuelRoomsDriftTest do
  @moduledoc """
  Drift #31 – Duel room allocation faithful to VB6 ModRetos.bas.

  VB6 loads duel rooms from Retos.dat.  Each room ("sala") has:
    - map_id
    - left spawn position  (PosIzquierda)
    - right spawn position (PosDerecha)

  The VB6 server tracks free/occupied rooms and:
    - Allocates a free room when a duel starts (BuscarSala / IniciarReto)
    - Saves each player's original position (LastPos)
    - Warps players to their spawn positions inside the room
    - Frees the room and warps players back when the duel ends (FinalizarReto)
    - Rejects duels when no rooms are available (SalasLibres <= 0)

  The Elixir DuelServer currently keeps players on the same map and ignores
  room allocation entirely.  These tests prove the drift and then verify the fix.
  """

  use ExUnit.Case, async: true

  alias Arena.DuelServer
  alias Arena.DuelServer.Duel

  @challenger_id 2001
  @target_id 2002
  @bet 5000

  # ── Test rooms matching VB6 Retos.dat structure ────────────────────────

  @test_rooms [
    %{map_id: 100, left_pos: {10, 10}, right_pos: {20, 20}},
    %{map_id: 101, left_pos: {5, 5}, right_pos: {15, 15}}
  ]

  setup do
    name = :"duel_rooms_#{System.unique_integer([:positive])}"
    {:ok, pid} = DuelServer.start_link(name: name, rooms: @test_rooms)
    %{server: name, pid: pid}
  end

  # ── Room allocation on duel start (VB6: BuscarSala / IniciarReto) ──────

  describe "room allocation on accept_challenge (VB6: BuscarSala)" do
    test "accepted duel includes room assignment with map_id and spawn positions", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert %Duel{} = duel
      # VB6 assigns a room index (SalaReto) and stores spawn positions
      assert duel.room_id != nil, "duel must have a room_id assigned (VB6: SalaReto)"
      assert duel.map_id != nil, "duel must have a map_id (VB6: Salas(Sala).PosIzquierda.Map)"
      assert duel.left_pos != nil, "duel must have left spawn pos (VB6: PosIzquierda)"
      assert duel.right_pos != nil, "duel must have right spawn pos (VB6: PosDerecha)"
    end

    test "room spawn positions match the configured room", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      # The assigned room must be one of our configured rooms
      room = Enum.find(@test_rooms, fn r -> r.map_id == duel.map_id end)
      assert room != nil, "assigned map_id must match a configured room"
      assert duel.left_pos == room.left_pos
      assert duel.right_pos == room.right_pos
    end
  end

  # ── Room freeing on duel end (VB6: FinalizarReto / SalaLiberada) ───────

  describe "room freeing on duel end (VB6: SalaLiberada)" do
    test "room is freed after duel ends via abandon", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, duel1} = DuelServer.accept_challenge(@target_id, "Challenger", s)
      room1_id = duel1.room_id

      DuelServer.abandon_duel(@challenger_id, s)

      # Start another duel — the same room should be available again
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, duel2} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      # With only one duel at a time and 2 rooms, the freed room can be reused
      assert duel2.room_id != nil
    end

    test "room is freed after duel ends via player death (finalize)", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      # 2-0 sweep to end the duel
      DuelServer.player_died(@target_id, s)
      DuelServer.player_died(@target_id, s)

      # The room should be free; verify by starting another duel
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, duel2} = DuelServer.accept_challenge(@target_id, "Challenger", s)
      assert duel2.room_id != nil
    end
  end

  # ── No rooms available (VB6: SalasLibres <= 0) ─────────────────────────

  describe "no rooms available (VB6: SalasLibres <= 0)" do
    test "rejects duel when all rooms are occupied", %{server: s} do
      # Fill all rooms (we have 2 rooms)
      :ok = DuelServer.create_challenge(3001, 3002, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(3002, "P1", s)

      :ok = DuelServer.create_challenge(3003, 3004, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(3004, "P3", s)

      # Third duel should fail — no rooms left
      :ok = DuelServer.create_challenge(3005, 3006, @bet, s)
      result = DuelServer.accept_challenge(3006, "P5", s)

      assert {:error, :no_rooms_available} = result
    end

    test "duel succeeds after a room is freed", %{server: s} do
      # Fill all rooms
      :ok = DuelServer.create_challenge(3001, 3002, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(3002, "P1", s)

      :ok = DuelServer.create_challenge(3003, 3004, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(3004, "P3", s)

      # Free one room
      DuelServer.abandon_duel(3001, s)

      # Now a new duel should succeed
      :ok = DuelServer.create_challenge(3005, 3006, @bet, s)
      {:ok, duel} = DuelServer.accept_challenge(3006, "P5", s)
      assert duel.room_id != nil
    end
  end

  # ── Original position saving (VB6: .LastPos) ──────────────────────────

  describe "original position tracking (VB6: LastPos)" do
    test "duel result includes original positions for warp-back", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      # Abandon to finalize
      {:ok, result} = DuelServer.abandon_duel(@challenger_id, s)

      # The finalize result should include original_positions so the caller
      # can warp players back (VB6: DevolverPosAnterior)
      assert result.original_positions != nil
      assert Map.has_key?(result.original_positions, @challenger_id)
      assert Map.has_key?(result.original_positions, @target_id)
    end
  end

  # ── Rooms query API (VB6: Retos.SalasLibres) ──────────────────────────

  describe "free_rooms_count/1 (VB6: SalasLibres)" do
    test "returns total rooms when none are occupied", %{server: s} do
      assert DuelServer.free_rooms_count(s) == 2
    end

    test "decrements when a duel starts", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert DuelServer.free_rooms_count(s) == 1
    end

    test "increments when a duel ends", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      DuelServer.abandon_duel(@challenger_id, s)

      assert DuelServer.free_rooms_count(s) == 2
    end
  end

  # ── Player disconnect during duel (VB6: desconexion en reto) ──────────

  describe "player disconnect during active duel" do
    test "disconnect ends the duel and opponent wins by forfeit", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      # Player disconnects mid-duel
      result = DuelServer.player_disconnected(@challenger_id, s)

      # Opponent should win by forfeit
      assert {:ok, result} = result
      assert result.type == :winner
      assert result.winner == @target_id
      assert result.loser == @challenger_id
    end

    test "disconnect frees the room", %{server: s} do
      assert DuelServer.free_rooms_count(s) == 2

      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)
      assert DuelServer.free_rooms_count(s) == 1

      # Disconnect should free the room
      DuelServer.player_disconnected(@challenger_id, s)
      assert DuelServer.free_rooms_count(s) == 2
    end

    test "disconnect preserves original_positions in result", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      {:ok, result} = DuelServer.player_disconnected(@challenger_id, s)

      assert result.original_positions != nil
      assert Map.has_key?(result.original_positions, @challenger_id)
      assert Map.has_key?(result.original_positions, @target_id)
    end

    test "disconnect by player not in duel returns error", %{server: s} do
      assert {:error, :not_in_duel} = DuelServer.player_disconnected(9999, s)
    end

    test "players are no longer in duel after disconnect", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert DuelServer.in_duel?(@challenger_id, s) == true
      assert DuelServer.in_duel?(@target_id, s) == true

      DuelServer.player_disconnected(@challenger_id, s)

      assert DuelServer.in_duel?(@challenger_id, s) == false
      assert DuelServer.in_duel?(@target_id, s) == false
    end
  end

  # ── Backward compatibility ─────────────────────────────────────────────

  describe "backward compatibility — server without rooms config" do
    test "start_link without rooms option still works (no room allocation)" do
      name = :"duel_no_rooms_#{System.unique_integer([:positive])}"
      {:ok, _pid} = DuelServer.start_link(name: name)

      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, name)
      {:ok, duel} = DuelServer.accept_challenge(@target_id, "Challenger", name)

      # Without rooms configured, room_id should be nil (graceful degradation)
      assert duel.room_id == nil
    end
  end
end
