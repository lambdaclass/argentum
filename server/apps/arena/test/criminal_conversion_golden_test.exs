defmodule Arena.CriminalConversionGoldenTest do
  @moduledoc """
  Golden fixture for the criminal-conversion flow
  (`Arena.Map.CriminalStatus.volver_criminal/3`), written against the
  deterministic scenario harness (`Arena.Test.Scenario`).

  Historical deterministic-parity golden work recorded in the root
  `CHANGELOG.md` — sibling of `healing_golden_test.exs`,
  `forgive_golden_test.exs`, `gamble_golden_test.exs`,
  `potions_golden_test.exs`, `bank_golden_test.exs`, and
  `trade_golden_test.exs`.

  Pins VB6 parity for `VolverCriminal` (Modulo_UsUaRiOs.bas:2260-2296):
    * Trigger 6 sanctuary tile short-circuit.
    * Caos / Concilio early return (cannot become criminal).
    * Ciudadano → Criminal `faction_score` reset.
    * Armada Real → Criminal retains `faction_score`.
    * NoPKs map warp via `Effects.transfer/5` (with GM bypass and
      missing/zero-Salida bypasses).
    * Party disband (leader path) and party leave (member path), both
      emitting the "Ahora sos criminal..." console message.

  Handler contract is `{entity, state, effects}` — *not* the standard
  `{:ok, state, effects}` used by service handlers. The local
  `run_volver_criminal/2` wrapper threads the updated entity back into
  `state.players` and reshapes to the harness's expected
  `{:ok, state, effects}` envelope.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.CriminalStatus

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Arena.PartyServer.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    # `Arena.PartyServer` is a singleton GenServer keyed by ETS table
    # `:ao_parties`. Wipe it between tests so leader/member fixtures get
    # a clean slate (mirrors `volver_criminal_test.exs`).
    :ets.delete_all_objects(:ao_parties)
    :ok
  end

  # ──────────────────────────────────────────────────────────────────────
  # Local helpers
  # ──────────────────────────────────────────────────────────────────────

  # Run the handler through the harness. `volver_criminal/3` returns
  # `{entity, state, effects}` (entity-first, no :ok tag), so we:
  #   1. Update `state.players[char_id]` with the returned entity (the
  #      handler does not do this itself — its callers thread the entity
  #      back through their own state map; see `combat_handlers.ex:482`).
  #   2. Reshape to `{:ok, state, effects}` for `Scenario.run/2`.
  defp run_volver_criminal(scenario, char_id) do
    run(scenario, fn state ->
      entity = Map.fetch!(state.players, char_id)
      {new_entity, state2, effects} = CriminalStatus.volver_criminal(state, char_id, entity)
      new_state = %{state2 | players: Map.put(state2.players, char_id, new_entity)}
      {:ok, new_state, effects}
    end)
  end

  defp citizen(opts \\ []) do
    Keyword.merge(
      [
        x: 50,
        y: 50,
        criminal: false,
        faction: :none,
        faction_score: 0,
        gm: false,
        gm_level: nil
      ],
      opts
    )
  end

  # ════════════════════════════════════════════════════════════════════
  # Branch 1 — Trigger 6 sanctuary tile
  # VB6:2263 — `MapData(.Pos.Map).ObjInfo(.Pos.X, .Pos.Y).Trigger = 6`.
  # ════════════════════════════════════════════════════════════════════

  describe "trigger 6 sanctuary" do
    test "player on trigger=6 tile: no-op (entity unchanged, no effects)" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{{50, 50} => 6}})
        |> with_player(:p, citizen(x: 50, y: 50, faction_score: 150))
        |> run_volver_criminal(:p)

      e = entity(s, :p)
      refute e.criminal, "VB6 early-returns when MapData(pos).Trigger == 6"
      assert e.faction_score == 150, "faction_score untouched on early return"
      assert emitted_effects(s) == [], "no effects emitted from sanctuary short-circuit"
    end

    test "trigger map with a different tile flagged: player still becomes criminal" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{{99, 99} => 6}})
        |> with_player(:p, citizen(x: 50, y: 50))
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal, "trigger=6 only matches the player's own tile"
    end

    test "empty trigger_map: player becomes criminal" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen())
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Branch 2 — Caos / Concilio early return
  # VB6:2271 — `If .Faccion.Status = e_Facciones.Caos OR Concilio` exits.
  # ════════════════════════════════════════════════════════════════════

  describe "caos / concilio early return" do
    test "chaos_legion: no-op (criminal flag and faction_score untouched)" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen(faction: :chaos_legion, faction_score: 500))
        |> run_volver_criminal(:p)

      e = entity(s, :p)
      refute e.criminal, "Caos players cannot become criminal"
      assert e.faction_score == 500, "faction_score must NOT be reset for Caos"
      assert emitted_effects(s) == []
    end

    test "council: no-op" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen(faction: :council, faction_score: 750))
        |> run_volver_criminal(:p)

      e = entity(s, :p)
      refute e.criminal, "Concilio players cannot become criminal"
      assert e.faction_score == 750
      assert emitted_effects(s) == []
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Branch 3 — Ciudadano (faction = :none) happy path
  # VB6:2272-2275 — Status = Ciudadano resets FactionScore = 0 then
  # promotes to Criminal.
  # ════════════════════════════════════════════════════════════════════

  describe "ciudadano → criminal" do
    test "criminal flag flips on, faction_score zeroed" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen(faction: :none, faction_score: 250))
        |> run_volver_criminal(:p)

      e = entity(s, :p)
      assert e.criminal, "VB6 sets .Criminal = True"
      assert e.faction_score == 0, "VB6 resets .FactionScore = 0 for Ciudadano"
    end

    test "ciudadano with zero score: still flips to criminal (idempotent reset)" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen(faction: :none, faction_score: 0))
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      assert entity(s, :p).faction_score == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Branch 4 — Armada Real → Criminal retains faction_score
  # VB6: only the Ciudadano branch zeroes FactionScore; Armada path
  # promotes to Criminal without touching the score.
  # ════════════════════════════════════════════════════════════════════

  describe "armada real → criminal" do
    test "criminal flag flips on, faction_score retained" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen(faction: :royal_army, faction_score: 1000))
        |> run_volver_criminal(:p)

      e = entity(s, :p)
      assert e.criminal
      assert e.faction_score == 1000, "Armada keeps FactionScore (only Ciudadanos lose it)"
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Branch 5 — NoPKs map warp
  # VB6:2276-2282 — emits Msg580 ("En este mapa no se admiten criminales.")
  # then warps to MapInfo(Map).Salida (skipped for GMs and when
  # Salida.Map = 0).
  # ════════════════════════════════════════════════════════════════════

  describe "no-pks map warp" do
    test "happy path: emits :transfer + 'no se admiten criminales.' console msg" do
      s =
        new(map_id: 1,
          meta: %{
            trigger_map: %{},
            no_pks: true,
            salida: %{map: 5, x: 60, y: 70}
          }
        )
        |> with_player(:p, citizen())
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      assert_effect(s, :transfer, to: :p, dest_map: 5, dest_xy: {60, 70})
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "GM (gm: true) bypasses warp" do
      s =
        new(map_id: 1,
          meta: %{
            trigger_map: %{},
            no_pks: true,
            salida: %{map: 5, x: 60, y: 70}
          }
        )
        |> with_player(:p, citizen(gm: true, gm_level: :admin))
        |> run_volver_criminal(:p)

      # GM still flips to criminal (the warp is the only thing skipped),
      # and emits no transfer / no criminal-zone msg.
      assert entity(s, :p).criminal
      refute_effect(s, :transfer)
      refute_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "GM detected via gm_level only (gm: false): also bypasses warp" do
      # `gm?/1` is `gm == true OR gm_level != nil` — exercise the
      # second clause in isolation.
      s =
        new(map_id: 1,
          meta: %{
            trigger_map: %{},
            no_pks: true,
            salida: %{map: 5, x: 60, y: 70}
          }
        )
        |> with_player(:p, citizen(gm: false, gm_level: :consejero))
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      refute_effect(s, :transfer)
    end

    test "no_pks: false: no warp even with valid Salida" do
      s =
        new(map_id: 1,
          meta: %{
            trigger_map: %{},
            no_pks: false,
            salida: %{map: 5, x: 60, y: 70}
          }
        )
        |> with_player(:p, citizen())
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      refute_effect(s, :transfer)
    end

    test "Salida.map == 0: invalid, no warp" do
      # VB6 also gates on `MapInfo(Map).Salida.Map <> 0`.
      s =
        new(map_id: 1,
          meta: %{
            trigger_map: %{},
            no_pks: true,
            salida: %{map: 0, x: 0, y: 0}
          }
        )
        |> with_player(:p, citizen())
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      refute_effect(s, :transfer)
    end

    test "missing :salida key: no warp" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}, no_pks: true})
        |> with_player(:p, citizen())
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      refute_effect(s, :transfer)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Branch 6 — Party disband / leave
  # VB6:2283-2291 — if in a party, send Msg2144 then FinalizarGrupo
  # (leader) or SalirDeGrupo (member). Our `PartyServer.leave/1`
  # already dispatches both.
  # ════════════════════════════════════════════════════════════════════

  describe "party disband / leave" do
    test "no party: no party msg, no leave call" do
      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(:p, citizen())
        |> run_volver_criminal(:p)

      assert entity(s, :p).criminal
      # Console messages from this branch only fire when in a party.
      refute_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "leader becoming criminal: party dissolves, console msg emitted" do
      :ok = Arena.PartyServer.invite(1001, 1002)
      :ok = Arena.PartyServer.accept_invite(1002)
      assert {:ok, _} = Arena.PartyServer.get_party(1001)

      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(1001, citizen())
        |> with_player(1002, citizen(x: 51, y: 50))
        |> run_volver_criminal(1001)

      assert entity(s, 1001).criminal
      assert_effect(s, :send, to: 1001, packet: :console_msg)

      # PartyServer.leave/1 is a cast; sync via a follow-up call
      # (handle_call is processed FIFO so this guarantees the cast ran).
      _ = Arena.PartyServer.get_party(1001)

      assert Arena.PartyServer.get_party(1001) == :not_in_party
      assert Arena.PartyServer.get_party(1002) == :not_in_party,
             "leader leaving dissolves the party (FinalizarGrupo)"
    end

    test "non-leader member becoming criminal: leaves, others remain grouped" do
      :ok = Arena.PartyServer.invite(2001, 2002)
      :ok = Arena.PartyServer.accept_invite(2002)
      :ok = Arena.PartyServer.invite(2001, 2003)
      :ok = Arena.PartyServer.accept_invite(2003)

      s =
        new(map_id: 1, meta: %{trigger_map: %{}})
        |> with_player(2001, citizen())
        |> with_player(2002, citizen(x: 51, y: 50))
        |> with_player(2003, citizen(x: 52, y: 50))
        |> run_volver_criminal(2002)

      assert entity(s, 2002).criminal
      assert_effect(s, :send, to: 2002, packet: :console_msg)

      # Sync on a call to flush the leave-cast through the GenServer.
      _ = Arena.PartyServer.get_party(2002)

      assert Arena.PartyServer.get_party(2002) == :not_in_party
      {:ok, party} = Arena.PartyServer.get_party(2001)
      assert party.leader == 2001
      assert 2001 in party.members
      assert 2003 in party.members
      refute 2002 in party.members
    end

    test "party + NoPKs warp combine: emits both :transfer and party console msg" do
      # Compound branch — exercise warp + party paths together to pin
      # the order-independent effect set.
      :ok = Arena.PartyServer.invite(3001, 3002)
      :ok = Arena.PartyServer.accept_invite(3002)

      s =
        new(map_id: 1,
          meta: %{
            trigger_map: %{},
            no_pks: true,
            salida: %{map: 7, x: 10, y: 20}
          }
        )
        |> with_player(3001, citizen())
        |> with_player(3002, citizen(x: 51, y: 50))
        |> run_volver_criminal(3001)

      assert entity(s, 3001).criminal
      assert_effect(s, :transfer, to: 3001, dest_map: 7, dest_xy: {10, 20})
      # Both the criminal-zone notice (from the warp branch) and the
      # "Ahora sos criminal..." party notice land as :send :console_msg
      # to the same char_id; assert at least one matches.
      assert_effect(s, :send, to: 3001, packet: :console_msg)
    end
  end
end
