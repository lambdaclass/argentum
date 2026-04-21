defmodule Arena.DuelHandlerTest do
  @moduledoc """
  Drift #3 — binary duel packet routing (VB6 Protocol.bas:5931-5981).

  These tests exercise the new `AoTcpGateway.SessionCommands.Duel` module
  end-to-end against a per-test `Arena.DuelServer` instance. They cover:

    * eDuel → `Arena.DuelServer.challenge/5` with `pociones_maximas` and
      `caen_items` preserved (VB6 CrearReto signature).
    * eAcceptDuel → `Arena.DuelServer.accept_challenge/3`.
    * eCancelDuel → `Arena.DuelServer.cancel_challenge/2`.
    * eQuitDuel → `Arena.DuelServer.abandon_duel/2`.
  """

  use ExUnit.Case, async: false

  alias Arena.DuelServer
  alias AoSession.OnlineDirectory
  alias AoTcpGateway.SessionCommands.Duel, as: DuelHandler

  @bet 2500

  setup do
    # The supervised DuelServer singleton is shared across tests; use
    # per-test unique character ids and clean up our directory entries.
    ensure_online_directory()

    # Generate unique ids so parallel DuelServer state doesn't collide.
    offset = System.unique_integer([:positive])
    challenger_id = 900_000 + offset
    target_id = 900_000 + offset + 1
    challenger_name = "Challenger#{offset}"
    target_name = "Target#{offset}"

    OnlineDirectory.register(challenger_id, challenger_name, 1, self())
    OnlineDirectory.register(target_id, target_name, 1, self())

    on_exit(fn ->
      OnlineDirectory.unregister(challenger_id)
      OnlineDirectory.unregister(target_id)
      # Clean up lingering DuelServer state for these ids so a subsequent
      # test does not observe a stale challenge or duel.
      _ = DuelServer.cancel_challenge(challenger_id)
      _ = DuelServer.abandon_duel(challenger_id)
      _ = DuelServer.abandon_duel(target_id)
    end)

    %{
      challenger_id: challenger_id,
      target_id: target_id,
      challenger_name: challenger_name,
      target_name: target_name
    }
  end

  defp ensure_online_directory() do
    case Process.whereis(OnlineDirectory) do
      nil -> {:ok, _} = OnlineDirectory.start_link()
      _pid -> :ok
    end
  end

  defp session_state(char_id) do
    %{
      character_id: char_id,
      map_id: 1,
      account_id: "a",
      entity: nil,
      target_x: nil,
      target_y: nil,
      is_gm: false,
      is_dead: false,
      in_commerce: false,
      in_bank: false
    }
  end

  # ── eDuel challenge ──────────────────────────────────────────────────

  describe "eDuel → DuelServer.challenge/5 (VB6: CrearReto)" do
    test "creates a pending challenge carrying pociones_maximas and caen_items", ctx do
      payload = %{
        target_username: ctx.target_name,
        bet: @bet,
        pociones_maximas: 15,
        caen_items: true
      }

      {_state, _packets} =
        DuelHandler.handle_command(session_state(ctx.challenger_id), {:duel, payload})

      challenge = DuelServer.get_challenge(ctx.challenger_id)

      assert challenge != nil, "expected a pending challenge"
      assert challenge.challenger_id == ctx.challenger_id
      assert challenge.target_id == ctx.target_id
      assert challenge.bet == @bet
      assert Map.get(challenge, :pociones_maximas) == 15
      assert Map.get(challenge, :caen_items) == true
    end

    test "records caen_items=false and pociones_maximas=0", ctx do
      payload = %{
        target_username: ctx.target_name,
        bet: 100,
        pociones_maximas: 0,
        caen_items: false
      }

      {_state, _packets} =
        DuelHandler.handle_command(session_state(ctx.challenger_id), {:duel, payload})

      challenge = DuelServer.get_challenge(ctx.challenger_id)
      assert Map.get(challenge, :pociones_maximas) == 0
      assert Map.get(challenge, :caen_items) == false
    end
  end

  # ── eAcceptDuel ───────────────────────────────────────────────────────

  describe "eAcceptDuel → DuelServer.accept_challenge/3 (VB6: AceptarReto)" do
    test "starts the duel when target accepts", ctx do
      :ok =
        DuelServer.challenge(
          ctx.challenger_id,
          ctx.target_id,
          @bet,
          %{pociones_maximas: 10, caen_items: true}
        )

      {_state, _packets} =
        DuelHandler.handle_command(
          session_state(ctx.target_id),
          {:accept_duel, %{target_username: ctx.challenger_name}}
        )

      assert DuelServer.in_duel?(ctx.challenger_id)
      assert DuelServer.in_duel?(ctx.target_id)
    end
  end

  # ── eCancelDuel ───────────────────────────────────────────────────────

  describe "eCancelDuel → DuelServer.cancel_challenge/2 (VB6: CancelarSolicitudReto)" do
    test "challenger cancels their pending challenge", ctx do
      :ok =
        DuelServer.challenge(
          ctx.challenger_id,
          ctx.target_id,
          @bet,
          %{pociones_maximas: 5, caen_items: true}
        )

      assert DuelServer.get_challenge(ctx.challenger_id) != nil

      {_state, _packets} =
        DuelHandler.handle_command(session_state(ctx.challenger_id), {:cancel_duel, %{}})

      assert DuelServer.get_challenge(ctx.challenger_id) == nil
    end
  end

  # ── eQuitDuel ─────────────────────────────────────────────────────────

  describe "eQuitDuel → DuelServer.abandon_duel/2 (VB6: AbandonarReto)" do
    test "abandoning player forfeits the active duel", ctx do
      :ok =
        DuelServer.challenge(
          ctx.challenger_id,
          ctx.target_id,
          @bet,
          %{pociones_maximas: 10, caen_items: true}
        )

      {:ok, _duel} = DuelServer.accept_challenge(ctx.target_id, ctx.challenger_name)

      {_state, _packets} =
        DuelHandler.handle_command(session_state(ctx.target_id), {:quit_duel, %{}})

      refute DuelServer.in_duel?(ctx.challenger_id)
      refute DuelServer.in_duel?(ctx.target_id)
    end
  end
end
