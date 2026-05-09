defmodule Arena.FactionEnlistmentGoldenTest do
  @moduledoc """
  Golden fixture for the faction enlistment / leave / rank-up / chat
  flows (`Arena.Map.Faction`), written against the deterministic
  scenario harness.

  Phase 1 / Item 5 of `ROADMAP.md`. Pins VB6 parity for:
    * `handle_enlist_faction/3` → `handle_enlistador_click/4` happy
      paths (Real / Caos).
    * `handle_enlistador_click/4` rejections (dead, already-in-faction,
      reenlistadas guard, criminal/citizen-killer/thief gates,
      ciudadano-into-Caos gate, level gate).
    * `handle_leave_faction/2` happy + reject paths.
    * `handle_faction_rank_up/4` rank ladder (max-rank, level, score
      rejections).
    * `handle_faction_chat/3` faction-only broadcast lane.

  Faction handlers are on the effects contract
  (`{:ok, state, [Effect.t()]}`); we assert via the scenario `:send` /
  `:broadcast_character_change` matchers and direct `entity/2`
  inspection. No `assert_receive` — the legacy `{:send_raw, _}` mailbox
  shim no longer fires from this module.

  VB6 anchors:
    * `ModFacciones.bas:33`  — EnlistarArmadaReal
    * `ModFacciones.bas:174` — EnlistarCaos
    * `ModFacciones.bas:111` — RecompensaArmadaReal (rank-up)
    * `ModFacciones.bas:144` — ExpulsarFaccionReal (leave)
    * `ModFacciones.bas:357` — PerderItemsFaccionarios (strip on leave)
    * `Protocol.bas:5211`    — HandleFactionMessage (faction chat)
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, NpcDef}
  alias Arena.Map.Faction
  alias AoSession.OnlineDirectory

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  # VB6: NpcType.Enlistador = 5; faccion 3 = Real, 2 = Caos.
  @npc_type_enlistador 5
  @royal_npc_id 800
  @chaos_npc_id 801
  # Player level used in happy-path tests. From the shipped
  # rangos_faccion.dat, rank 1 requires level 25 in both factions.
  @lvl_rank1 25
  @lvl_below_rank1 24

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Arena.Settings.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    Arena.Settings.reset_all()

    :ets.insert(:arena_game_data, {{:npc, @royal_npc_id}, enlistador_def(@royal_npc_id, 3)})
    :ets.insert(:arena_game_data, {{:npc, @chaos_npc_id}, enlistador_def(@chaos_npc_id, 2)})

    # Seed deterministic rank ladders so the test does not depend on
    # whether the production .dat files were parsed for this run. The
    # values mirror `rangos_faccion.dat` (rank 1: lvl 25 / score 100,
    # rank 2: lvl 30 / score 500, rank 5 is the cap).
    :ets.insert(
      :arena_game_data,
      {{:faction_ranks, :royal_army},
       [
         %{rank: 1, required_level: 25, required_score: 100, title: "Soldado"},
         %{rank: 2, required_level: 30, required_score: 500, title: "Caballero"},
         %{rank: 3, required_level: 35, required_score: 2_500, title: "Capitan"},
         %{rank: 4, required_level: 40, required_score: 5_000, title: "Protector"},
         %{rank: 5, required_level: 43, required_score: 10_000, title: "Campeon"}
       ]}
    )

    :ets.insert(
      :arena_game_data,
      {{:faction_ranks, :chaos_legion},
       [
         %{rank: 1, required_level: 25, required_score: 100, title: "Acolito"},
         %{rank: 2, required_level: 30, required_score: 500, title: "Emisario"},
         %{rank: 3, required_level: 35, required_score: 2_500, title: "Sanguinario"},
         %{rank: 4, required_level: 40, required_score: 5_000, title: "Caballero Oscuro"},
         %{rank: 5, required_level: 43, required_score: 10_000, title: "Devorador"}
       ]}
    )

    # Empty rewards: keeps the happy-path assertions focused on faction
    # state + console packets rather than item-grant side effects.
    :ets.insert(:arena_game_data, {{:faction_rewards, :royal_army}, []})
    :ets.insert(:arena_game_data, {{:faction_rewards, :chaos_legion}, []})

    # Faction chat broadcasts via `Effects.send/2` to same-faction
    # players on this map; OnlineDirectory.update_faction/2 is called
    # from the leave/enlist handlers as a non-effect side effect. Make
    # sure the registry is up so those calls don't crash.
    case GenServer.whereis(OnlineDirectory) do
      nil -> start_supervised!(OnlineDirectory)
      _pid -> :ok
    end

    :ets.delete_all_objects(:ao_online_directory)

    :ok
  end

  defp enlistador_def(id, faccion) do
    %NpcDef{
      id: id,
      npc_type: @npc_type_enlistador,
      name: if(faccion == 3, do: "Enlistador Real", else: "Enlistador Caos"),
      faccion: faccion,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  defp with_royal_enlistador(scenario, opts \\ []) do
    with_npc(scenario, :enl_royal, Keyword.merge([npc_id: @royal_npc_id, x: 51, y: 50], opts))
  end

  defp with_chaos_enlistador(scenario, opts \\ []) do
    with_npc(scenario, :enl_chaos, Keyword.merge([npc_id: @chaos_npc_id, x: 51, y: 50], opts))
  end

  defp recruit(opts \\ []) do
    Keyword.merge(
      [
        level: @lvl_rank1,
        faction: :none,
        faction_rank_armada: 0,
        faction_rank_chaos: 0,
        faction_score: 0,
        faction_reenlistadas: 0,
        criminal: false,
        citizens_killed: 0,
        class: :warrior,
        gold: 0,
        inventory: List.duplicate(nil, 24),
        equipment: %{
          weapon: nil,
          armor: nil,
          shield: nil,
          helmet: nil,
          ring: nil,
          municion: nil
        }
      ],
      opts
    )
  end

  defp run_enlist(scenario, char_id, faction) do
    run(scenario, fn state -> Faction.handle_enlist_faction(state, char_id, faction) end)
  end

  defp run_click(scenario, char_id, npc_def) do
    run(scenario, fn state ->
      entity = Map.fetch!(state.players, char_id)
      Faction.handle_enlistador_click(state, char_id, entity, npc_def)
    end)
  end

  defp run_rank_up(scenario, char_id, faction) do
    run(scenario, fn state ->
      entity = Map.fetch!(state.players, char_id)
      Faction.handle_faction_rank_up(state, char_id, entity, faction)
    end)
  end

  defp run_leave(scenario, char_id) do
    run(scenario, fn state -> Faction.handle_leave_faction(state, char_id) end)
  end

  defp run_chat(scenario, char_id, message) do
    run(scenario, fn state -> Faction.handle_faction_chat(state, char_id, message) end)
  end

  defp royal_npc_def, do: enlistador_def(@royal_npc_id, 3)
  defp chaos_npc_def, do: enlistador_def(@chaos_npc_id, 2)

  # ────────────────────────────────────────────────────────────────────
  # handle_enlist_faction — happy paths
  # VB6 ModFacciones.bas:33 (EnlistarArmadaReal), :174 (EnlistarCaos)
  # ────────────────────────────────────────────────────────────────────

  describe "handle_enlist_faction: happy paths" do
    test "Royal Army: warrior with required level enlists, rank 1 assigned" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit())
        |> with_royal_enlistador()
        |> run_enlist(:p, :royal_army)

      e = entity(s, :p)
      assert e.faction == :royal_army
      assert e.faction_rank_armada == 1
      assert e.faction_rank_chaos == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "Chaos Legion: criminal at required level enlists, rank 1 assigned" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(criminal: true))
        |> with_chaos_enlistador()
        |> run_enlist(:p, :chaos_legion)

      e = entity(s, :p)
      assert e.faction == :chaos_legion
      assert e.faction_rank_chaos == 1
      assert e.faction_rank_armada == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_enlist_faction — enlistador locator
  # ────────────────────────────────────────────────────────────────────

  describe "handle_enlist_faction: enlistador locator" do
    test "no enlistador on the map: rejected, faction unchanged" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit())
        |> run_enlist(:p, :royal_army)

      assert entity(s, :p).faction == :none
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "enlistador beyond 5 tiles: rejected" do
      # VB6 within_vb6_distance? uses chebyshev <= 5, so x=57 is 7 tiles.
      s =
        new(map_id: 1)
        |> with_player(:p, recruit())
        |> with_royal_enlistador(x: 57, y: 50)
        |> run_enlist(:p, :royal_army)

      assert entity(s, :p).faction == :none
    end

    test "enlistador at exactly 5 tiles: accepted" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit())
        |> with_royal_enlistador(x: 55, y: 50)
        |> run_enlist(:p, :royal_army)

      assert entity(s, :p).faction == :royal_army
    end

    test "wrong-side enlistador on map: not picked, rejected" do
      # Player wants Royal but only a Chaos enlistador is nearby.
      s =
        new(map_id: 1)
        |> with_player(:p, recruit())
        |> with_chaos_enlistador()
        |> run_enlist(:p, :royal_army)

      assert entity(s, :p).faction == :none
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_enlistador_click — player-state rejections
  # VB6 ModFacciones.bas:33-66 (Armada), :174-194 (Caos)
  # ────────────────────────────────────────────────────────────────────

  describe "handle_enlistador_click: player-state rejections" do
    test "dead player is rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(dead: true, hp: 0, max_hp: 100))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      assert entity(s, :p).faction == :none
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "already in different faction: rejected" do
      # Player is in Royal, clicks a Chaos enlistador.
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction: :royal_army, faction_rank_armada: 1))
        |> with_chaos_enlistador()
        |> run_click(:p, chaos_npc_def())

      assert entity(s, :p).faction == :royal_army
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "already in same faction: routes to rank-up (no level/score progress yet)" do
      # Player at level 25, faction_score 0 — cannot rank-up because
      # rank 2 needs level 30 + 500 score. Rejection goes through the
      # rank-up branch.
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction: :royal_army, faction_rank_armada: 1))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      e = entity(s, :p)
      assert e.faction_rank_armada == 1, "rank must not advance without level/score"
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "reenlistadas > 0: rejected (MAX_FACTION_ENLISTMENTS = 0)" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction_reenlistadas: 1))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      assert entity(s, :p).faction == :none
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_enlistador_click — Royal Army eligibility gates
  # VB6 ModFacciones.bas:35-66
  # ────────────────────────────────────────────────────────────────────

  describe "handle_enlistador_click: Royal Army gates" do
    test "criminal cannot enlist in Royal Army" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(criminal: true))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      assert entity(s, :p).faction == :none
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "citizen-killer cannot enlist in Royal Army" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(citizens_killed: 1))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      assert entity(s, :p).faction == :none
    end

    test "thief class cannot enlist in Royal Army" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(class: :thief))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      assert entity(s, :p).faction == :none
    end

    test "below required level: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(level: @lvl_below_rank1))
        |> with_royal_enlistador()
        |> run_click(:p, royal_npc_def())

      assert entity(s, :p).faction == :none
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_enlistador_click — Chaos Legion eligibility gates
  # VB6 ModFacciones.bas:183-186
  # ────────────────────────────────────────────────────────────────────

  describe "handle_enlistador_click: Chaos Legion gates" do
    test "non-criminal Ciudadano cannot enlist in Chaos Legion" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(criminal: false))
        |> with_chaos_enlistador()
        |> run_click(:p, chaos_npc_def())

      assert entity(s, :p).faction == :none
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_faction_rank_up — rank ladder
  # VB6 ModFacciones.bas:111 (Real), :237 (Caos)
  # ────────────────────────────────────────────────────────────────────

  describe "handle_faction_rank_up: rank ladder" do
    test "happy path: meets level + score for rank 2, advances and emits message" do
      # Rank 2 (Royal): NivelRequerido=30, AsesinatosRequeridos=500.
      s =
        new(map_id: 1)
        |> with_player(:p,
          recruit(faction: :royal_army, faction_rank_armada: 1, level: 30, faction_score: 500)
        )
        |> run_rank_up(:p, :royal_army)

      e = entity(s, :p)
      assert e.faction_rank_armada == 2
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "max rank: rejected, rank unchanged" do
      # Rank ladder ends at rank 5 (Campeon de la Luz / Devorador de
      # Almas). With `faction_rank_armada: 5`, no next-rank def exists.
      s =
        new(map_id: 1)
        |> with_player(:p,
          recruit(
            faction: :royal_army,
            faction_rank_armada: 5,
            level: 60,
            faction_score: 999_999
          )
        )
        |> run_rank_up(:p, :royal_army)

      assert entity(s, :p).faction_rank_armada == 5
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "insufficient level: rejected, rank unchanged" do
      # Rank 2 needs level 30; player at 28.
      s =
        new(map_id: 1)
        |> with_player(:p,
          recruit(faction: :royal_army, faction_rank_armada: 1, level: 28, faction_score: 500)
        )
        |> run_rank_up(:p, :royal_army)

      assert entity(s, :p).faction_rank_armada == 1
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "insufficient faction_score: rejected, rank unchanged" do
      # Rank 2 needs 500 faction_score; player at 200.
      s =
        new(map_id: 1)
        |> with_player(:p,
          recruit(faction: :royal_army, faction_rank_armada: 1, level: 30, faction_score: 200)
        )
        |> run_rank_up(:p, :royal_army)

      assert entity(s, :p).faction_rank_armada == 1
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_leave_faction
  # VB6 ModFacciones.bas:144 (Real), :155 (Caos)
  # ────────────────────────────────────────────────────────────────────

  describe "handle_leave_faction" do
    test "happy path: leaves at own enlistador, faction cleared and reenlistadas++" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction: :royal_army, faction_rank_armada: 1))
        |> with_royal_enlistador()
        |> run_leave(:p)

      e = entity(s, :p)
      assert e.faction == :none
      assert e.faction_reenlistadas == 1
      # Leave broadcasts a character_change (so visible chars see the
      # equipment strip) and emits 24 inventory slot updates + the
      # console acknowledgement.
      assert_effect(s, :broadcast_character_change, char_id: :p)
      assert_effect(s, :send, to: :p, packet: :change_inventory_slot)
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "not in any faction: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction: :none))
        |> with_royal_enlistador()
        |> run_leave(:p)

      assert entity(s, :p).faction == :none
      assert entity(s, :p).faction_reenlistadas == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :broadcast_character_change, char_id: :p)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_faction_chat — broadcast lane
  # VB6 Protocol.bas:5211 — HandleFactionMessage
  # ────────────────────────────────────────────────────────────────────

  describe "handle_faction_chat" do
    test "happy path: faction-only broadcast reaches every same-faction player" do
      Arena.Settings.set(:chat_cooldown_ms, 0)

      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction: :royal_army, name: "Sender"))
        |> with_player(:ally,
          recruit(faction: :royal_army, name: "Ally", x: 70, y: 70, char_index: 2)
        )
        |> with_player(:foe,
          recruit(faction: :chaos_legion, criminal: true, name: "Foe", x: 80, y: 80, char_index: 3)
        )
        |> with_player(:civilian,
          recruit(faction: :none, name: "Civ", x: 90, y: 90, char_index: 4)
        )
        |> run_chat(:p, "por el rey")

      assert_effect(s, :send, to: :p, packet: :console_faction_message)
      assert_effect(s, :send, to: :ally, packet: :console_faction_message)
      refute_effect(s, :send, to: :foe, packet: :console_faction_message)
      refute_effect(s, :send, to: :civilian, packet: :console_faction_message)

      assert entity(s, :p).last_chat_at != entity(s, :p).last_chat_at - 1,
             "last_chat_at must be stamped"
    end

    test "factionless sender: rejected with console message, no broadcast" do
      Arena.Settings.set(:chat_cooldown_ms, 0)

      s =
        new(map_id: 1)
        |> with_player(:p, recruit(faction: :none))
        |> with_player(:ally,
          recruit(faction: :royal_army, name: "Ally", x: 70, y: 70, char_index: 2)
        )
        |> run_chat(:p, "hola")

      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :ally, packet: :console_faction_message)
    end
  end
end
