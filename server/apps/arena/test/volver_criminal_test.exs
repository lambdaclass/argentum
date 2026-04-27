defmodule Arena.VolverCriminalTest do
  @moduledoc """
  Drift #15 — port of VB6 `VolverCriminal` (Modulo_UsUaRiOs.bas:2260-2296).

  Covers behaviours the one-liner in combat_handlers.ex:515-517 was losing:
    * trigger=6 tile prevents becoming criminal (safe zone)
    * faction_score is zeroed when previously Ciudadano
    * player is warped out of NoPKs maps to MapInfo(Map).Salida
    * in-party players have the party disbanded (leader + member paths)
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.CriminalStatus

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arena.PartyServer.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides) do
    Map.merge(
      %{
        char_id: :player,
        name: "Tester",
        account_id: "acc_test",
        x: 50,
        y: 50,
        heading: :south,
        hp: 100,
        max_hp: 100,
        level: 25,
        class: :warrior,
        race: :human,
        gender: :male,
        gold: 0,
        inventory: List.duplicate(nil, 24),
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
        skills: %{},
        spells: [],
        buffs: [],
        dead: false,
        poisoned: false,
        criminal: false,
        invisible: false,
        oculto: false,
        paralyzed: false,
        meditating: false,
        resting: false,
        safe_mode: false,
        navigating: false,
        gm: false,
        gm_level: nil,
        faction: :none,
        faction_score: 0,
        faction_rank_armada: 0,
        faction_rank_chaos: 0,
        faction_reenlistadas: 0,
        faction_kills_royal: 0,
        faction_kills_chaos: 0,
        citizens_killed: 0,
        criminals_killed: 0,
        char_index: 1,
        map_id: 1
      },
      overrides
    )
  end

  defp state_with(player, meta_overrides \\ %{}) do
    meta =
      Map.merge(
        %{
          safe_zone: false,
          no_pks: false,
          salida: nil,
          trigger_map: %{},
          rain: false,
          sin_invi_ocul: false
        },
        meta_overrides
      )

    map_state(
      players: %{player.char_id => player},
      sessions: %{player.char_id => self()},
      meta: meta
    )
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  setup do
    # Wipe the PartyServer ETS table between tests.
    :ets.delete_all_objects(:ao_parties)
    flush_mailbox()
    :ok
  end

  # ── trigger=6 sanctuary tile short-circuit ───────────────────────────────

  describe "trigger=6 sanctuary tile" do
    test "player standing on trigger=6 does NOT become criminal" do
      entity = make_entity(%{x: 50, y: 50, criminal: false})
      state = state_with(entity, %{trigger_map: %{{50, 50} => 6}})

      {new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      assert new_entity.criminal == false,
             "VB6 VolverCriminal early-returns when MapData(pos).trigger == 6"
    end

    test "player NOT on a trigger=6 tile DOES become criminal" do
      entity = make_entity(%{x: 50, y: 50, criminal: false})
      state = state_with(entity, %{trigger_map: %{}})

      {new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      assert new_entity.criminal == true
    end
  end

  # ── FactionScore reset on Ciudadano→Criminal ─────────────────────────────

  describe "faction_score reset" do
    test "faction_score is zeroed when previous status was Ciudadano" do
      # Ciudadano in VB6 = no faction (Status = 0) with positive FactionScore.
      entity = make_entity(%{faction: :none, faction_score: 150, criminal: false})
      state = state_with(entity)

      {new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      assert new_entity.criminal == true
      assert new_entity.faction_score == 0,
             "VB6 resets FactionScore = 0 when transitioning from Ciudadano"
    end

    test "Caos / Armada retain their faction_score (unaffected)" do
      # VB6: if Faccion.Status = Caos OR Concilio, the whole Sub exits early,
      # so faction_score is never touched.  For Armada (Real) it also shouldn't
      # be zeroed (only Ciudadano branch zeroes it).
      entity = make_entity(%{faction: :chaos_legion, faction_score: 500, criminal: false})
      state = state_with(entity)

      {new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      assert new_entity.faction_score == 500
      # Caos/Concilio early-return -> entity unchanged
      assert new_entity.criminal == false
    end
  end

  # ── NoPKs warp ───────────────────────────────────────────────────────────

  describe "NoPKs map warp" do
    test "player on NoPKs map is warped to Salida" do
      entity = make_entity(%{x: 50, y: 50, gm: false, criminal: false})

      state =
        state_with(entity, %{
          no_pks: true,
          salida: %{map: 5, x: 60, y: 70}
        })

      {new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      assert new_entity.criminal == true
      assert_receive {:transfer, 5, 60, 70, _entity}, 200
    end

    test "GM is NOT warped from NoPKs map" do
      entity =
        make_entity(%{x: 50, y: 50, gm: true, gm_level: :admin, criminal: false})

      state =
        state_with(entity, %{
          no_pks: true,
          salida: %{map: 5, x: 60, y: 70}
        })

      {_new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      refute_receive {:transfer, _, _, _, _}, 50
    end

    test "non-NoPKs map is not affected" do
      entity = make_entity(%{criminal: false})

      state =
        state_with(entity, %{
          no_pks: false,
          salida: %{map: 5, x: 60, y: 70}
        })

      {_new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      refute_receive {:transfer, _, _, _, _}, 50
    end

    test "NoPKs map with Salida.Map == 0 does not warp" do
      # VB6 also checks `MapInfo(Map).Salida.Map <> 0`.
      entity = make_entity(%{criminal: false})

      state =
        state_with(entity, %{
          no_pks: true,
          salida: %{map: 0, x: 0, y: 0}
        })

      {_new_entity, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, :player, entity)

      refute_receive {:transfer, _, _, _, _}, 50
    end
  end

  # ── Party disband ────────────────────────────────────────────────────────

  describe "party disband" do
    test "leader becoming criminal dissolves the party" do
      leader = make_entity(%{char_id: 1001, name: "Leader", criminal: false})
      member = make_entity(%{char_id: 1002, name: "Member", criminal: false})

      # Form a party: leader invites, member accepts.
      :ok = Arena.PartyServer.invite(leader.char_id, member.char_id)
      :ok = Arena.PartyServer.accept_invite(member.char_id)
      assert {:ok, _} = Arena.PartyServer.get_party(leader.char_id)

      state =
        map_state(
          players: %{leader.char_id => leader, member.char_id => member},
          sessions: %{leader.char_id => self(), member.char_id => self()},
          meta: %{safe_zone: false, no_pks: false, salida: nil, trigger_map: %{}, rain: false}
        )

      {new_leader, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, leader.char_id, leader)

      assert new_leader.criminal == true
      # Allow PartyServer cast to process.
      Process.sleep(20)

      assert Arena.PartyServer.get_party(leader.char_id) == :not_in_party
      assert Arena.PartyServer.get_party(member.char_id) == :not_in_party
    end

    test "non-leader member becoming criminal leaves the party (others remain)" do
      leader = make_entity(%{char_id: 2001, name: "Leader2", criminal: false})
      member = make_entity(%{char_id: 2002, name: "Member2", criminal: false})
      other = make_entity(%{char_id: 2003, name: "Other2", criminal: false})

      :ok = Arena.PartyServer.invite(leader.char_id, member.char_id)
      :ok = Arena.PartyServer.accept_invite(member.char_id)
      :ok = Arena.PartyServer.invite(leader.char_id, other.char_id)
      :ok = Arena.PartyServer.accept_invite(other.char_id)

      state =
        map_state(
          players: %{
            leader.char_id => leader,
            member.char_id => member,
            other.char_id => other
          },
          sessions: %{
            leader.char_id => self(),
            member.char_id => self(),
            other.char_id => self()
          },
          meta: %{safe_zone: false, no_pks: false, salida: nil, trigger_map: %{}, rain: false}
        )

      {new_member, _new_state, _vc_effects} = CriminalStatus.volver_criminal(state, member.char_id, member)

      assert new_member.criminal == true
      Process.sleep(20)

      # Member left; leader + other still grouped.
      assert Arena.PartyServer.get_party(member.char_id) == :not_in_party
      {:ok, party} = Arena.PartyServer.get_party(leader.char_id)
      assert party.leader == leader.char_id
      assert leader.char_id in party.members
      assert other.char_id in party.members
      refute member.char_id in party.members
    end
  end
end
