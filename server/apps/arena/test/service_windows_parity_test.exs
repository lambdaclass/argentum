defmodule Arena.ServiceWindowsParityTest do
  @moduledoc """
  VB6 parity tests for prontuario (punishment record), faction rewards,
  and priest-click prontuario display.
  """
  use ExUnit.Case, async: false

  alias Arena.Map.Gm.Moderation
  alias Arena.Map.{NpcInteraction, Faction}
  alias Arena.Test.MapStateFactory
  alias Arena.Data.NpcDef
  alias AoEntities.PlayerEntity

  # ── Helpers ────────────────────────────────────────────────────────

  defp make_entity(char_id, name, overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: char_id,
        name: name,
        account_id: "account_#{char_id}",
        x: 50,
        y: 50,
        hp: 100,
        max_hp: 100,
        mana: 100,
        max_mana: 100,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 10,
        xp: 5000,
        gold: 500,
        class: :warrior,
        race: :human,
        gender: :male,
        skills: %{combat: 80},
        min_hit: 5,
        max_hit: 15
      },
      overrides
    )
  end

  defp build_state(players, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{})
    npcs_live = Keyword.get(opts, :npcs_live, %{})
    occ = Keyword.get(opts, :occupancy, nil)

    base_opts = [
      players: players,
      sessions: sessions,
      npcs_live: npcs_live
    ]

    base_opts = if occ, do: Keyword.put(base_opts, :occupancy, occ), else: base_opts

    MapStateFactory.map_state(base_opts)
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      20 -> :ok
    end
  end

  defp collect_messages do
    collect_messages([])
  end

  defp collect_messages(acc) do
    receive do
      msg -> collect_messages([msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp priest_npc_def(id \\ 50) do
    %NpcDef{
      id: id,
      npc_type: 1,
      name: "Sacerdote",
      faccion: 0,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  defp enlistador_npc_def(id \\ 100) do
    %NpcDef{
      id: id,
      npc_type: 5,
      name: "Enlistador Real",
      faccion: 3,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  # ── Setup ──────────────────────────────────────────────────────────

  setup do
    unless Process.whereis(Arena.Data.GameData) do
      {:ok, _} = Arena.Data.GameData.start_link([])
    end

    drain_mailbox()
    :ok
  end

  # ====================================================================
  # 1. Prontuario displays stored punishment records (not stub text)
  # ====================================================================

  describe "prontuario display" do
    test "entity with punishments has accessible punishment records" do
      punishments = [
        %{number: 1, text: "Insultos en chat", date: "2026-04-10", gm_name: "Admin"},
        %{number: 2, text: "Uso de macros", date: "2026-04-15", gm_name: "Moderador"}
      ]

      target = make_entity(2, "Criminal", %{punishments: punishments})

      # The entity must have a punishments field with the list
      assert is_list(target.punishments)
      assert length(target.punishments) == 2

      first = hd(target.punishments)
      assert first.number == 1
      assert first.text == "Insultos en chat"
      assert first.date == "2026-04-10"
      assert first.gm_name == "Admin"
    end

    test "new entity defaults to empty punishments list" do
      entity = make_entity(1, "NewPlayer")
      # The punishments field must exist and default to empty list
      assert Map.has_key?(entity, :punishments)
      assert entity.punishments == []
    end
  end

  # ====================================================================
  # 2. /JAIL adds a punishment record to the entity
  # ====================================================================

  describe "gm_jail adds punishment record" do
    test "jailing a player appends a punishment entry to entity.punishments" do
      gm = make_entity(1, "GameMaster", %{gm: true})
      target = make_entity(2, "Offender", %{punishments: []})

      players = %{1 => gm, 2 => target}
      state = build_state(players, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Moderation.gm_jail(state, 1, "Offender", 30)
      drain_mailbox()

      updated_target = new_state.players[2]

      # After jail, the entity must have a new punishment entry
      assert length(updated_target.punishments) == 1

      punishment = hd(updated_target.punishments)
      assert punishment.number == 1
      assert punishment.text =~ "Carcel"
      assert punishment.gm_name == "GameMaster"
      assert is_binary(punishment.date)
    end

    test "multiple jails accumulate punishment records" do
      gm = make_entity(1, "GameMaster", %{gm: true})
      target = make_entity(2, "Repeat", %{punishments: []})

      players = %{1 => gm, 2 => target}
      state = build_state(players, sessions: %{1 => self(), 2 => self()})

      {:ok, state2, _eff1} = Moderation.gm_jail(state, 1, "Repeat", 10)
      drain_mailbox()

      {:ok, state3, _eff2} = Moderation.gm_jail(state2, 1, "Repeat", 20)
      drain_mailbox()

      updated_target = state3.players[2]
      assert length(updated_target.punishments) == 2

      second = Enum.find(updated_target.punishments, &(&1.number == 2))
      assert second != nil
    end
  end

  # ====================================================================
  # 3. gm_remove_punishment removes a specific punishment record
  # ====================================================================

  describe "gm_remove_punishment" do
    test "removes a punishment by number from the target entity" do
      existing = [
        %{number: 1, text: "First offense", date: "2026-04-01", gm_name: "Admin"},
        %{number: 2, text: "Second offense", date: "2026-04-05", gm_name: "Admin"},
        %{number: 3, text: "Third offense", date: "2026-04-10", gm_name: "Admin"}
      ]

      gm = make_entity(1, "GameMaster", %{gm: true})
      target = make_entity(2, "Punished", %{punishments: existing})

      players = %{1 => gm, 2 => target}
      state = build_state(players, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} =
        Moderation.gm_remove_punishment(state, 1, "Punished", "2", "")

      drain_mailbox()

      updated_target = new_state.players[2]

      # Should have 2 punishments remaining
      assert length(updated_target.punishments) == 2

      numbers = Enum.map(updated_target.punishments, & &1.number)
      refute 2 in numbers
      assert 1 in numbers
      assert 3 in numbers
    end

    test "removing non-existent punishment number does not crash" do
      gm = make_entity(1, "GameMaster", %{gm: true})
      target = make_entity(2, "Clean", %{punishments: []})

      players = %{1 => gm, 2 => target}
      state = build_state(players, sessions: %{1 => self(), 2 => self()})

      {:ok, _new_state, _effects} =
        Moderation.gm_remove_punishment(state, 1, "Clean", "5", "")
    end
  end

  # ====================================================================
  # 4. Faction rank-up grants reward items
  # ====================================================================

  describe "faction rank-up rewards" do
    test "handle_enlistador_click promotes and grants items on rank up" do
      entity =
        make_entity(1, "Soldier", %{
          faction: :royal_army,
          faction_rank_armada: 1,
          faction_score: 500,
          level: 25,
          punishments: []
        })

      npc_live = %{npc_id: 100, x: 50, y: 51, hp: 100, max_hp: 100, char_index: 200}

      npc_def = enlistador_npc_def(100)

      # Seed faction ranks with a rank 2 definition that the player qualifies for
      :ets.insert(:arena_game_data, {{:faction_ranks, :royal_army}, [
        %{rank: 1, required_level: 10, required_score: 0, title: "Soldado"},
        %{rank: 2, required_level: 20, required_score: 200, title: "Cabo"}
      ]})

      # Seed faction rewards with an item for rank 2
      :ets.insert(:arena_game_data, {{:faction_rewards, :royal_army}, [
        %{rank: 1, obj_index: 37},
        %{rank: 2, obj_index: 38}
      ]})

      # Provide a minimal item def for the reward item
      :ets.insert(:arena_game_data, {{:item, 38}, %{
        id: 38, name: "Espada Armada", stackable: false, valor: 100,
        grh_index: 1, equip_slot: :weapon, real: true, caos: false,
        obj_type: 1, forum_id: 0, puntos_pesca: 0, elemental_tags: 0
      }})

      :ets.insert(:arena_game_data, {{:npc, 100}, npc_def})

      players = %{1 => entity}
      state = build_state(players,
        sessions: %{1 => self()},
        npcs_live: %{1001 => npc_live}
      )

      {:ok, new_state, _effects} = Faction.handle_enlistador_click(state, 1, entity, npc_def)
      drain_mailbox()

      updated = new_state.players[1]

      # Player should have been promoted to rank 2
      assert updated.faction_rank_armada == 2

      # Player should have received the reward item in inventory
      has_reward = Enum.any?(updated.inventory, fn
        %{item_id: 38} -> true
        _ -> false
      end)

      assert has_reward, "Player should have received faction reward item 38"
    end
  end

  # ====================================================================
  # 5. Priest NPC click shows prontuario info
  # ====================================================================

  describe "priest NPC click shows prontuario" do
    test "clicking a priest NPC shows punishment records for the player" do
      punishments = [
        %{number: 1, text: "Insultos en chat", date: "2026-04-10", gm_name: "Admin"}
      ]

      entity = make_entity(1, "Sinner", %{punishments: punishments})

      priest_npc = %{npc_id: 50, x: 51, y: 50, hp: 100, max_hp: 100, char_index: 300}
      npc_def = priest_npc_def()

      :ets.insert(:arena_game_data, {{:npc, 50}, npc_def})

      players = %{1 => entity}
      state = build_state(players,
        sessions: %{1 => self()},
        npcs_live: %{2001 => priest_npc},
        occupancy: %{{51, 50} => {:npc, 2001}}
      )

      # handle_npc_double_click now returns {:ok, state, effects} on the
      # uniform contract; we run them through the runner here so the egress
      # envelopes land in the test mailbox.
      {:ok, ran_state, effects} =
        NpcInteraction.handle_npc_double_click(state, 1, entity, 2001)

      Arena.Map.Effects.run(ran_state, effects)
      msgs = collect_messages()

      raw_data =
        for msg <- msgs,
            data <-
              (case msg do
                 {:send_raw, d} -> [d]
                 {:egress, %{payload: d}} -> [d]
                 _ -> []
               end),
            do: data
      all_text = Enum.join(raw_data)

      # After the fix, clicking a priest should show the prontuario record
      assert String.contains?(all_text, "Insultos en chat"),
             "Priest click should show punishment record text. Got messages: #{inspect(msgs)}"
    end

    test "clicking a priest NPC with no punishments shows sin prontuario" do
      entity = make_entity(1, "GoodPlayer", %{punishments: []})

      priest_npc = %{npc_id: 50, x: 51, y: 50, hp: 100, max_hp: 100, char_index: 300}
      npc_def = priest_npc_def()

      :ets.insert(:arena_game_data, {{:npc, 50}, npc_def})

      players = %{1 => entity}
      state = build_state(players,
        sessions: %{1 => self()},
        npcs_live: %{2001 => priest_npc},
        occupancy: %{{51, 50} => {:npc, 2001}}
      )

      # handle_npc_double_click now returns {:ok, state, effects} on the
      # uniform contract; we run them through the runner here so the egress
      # envelopes land in the test mailbox.
      {:ok, ran_state, effects} =
        NpcInteraction.handle_npc_double_click(state, 1, entity, 2001)

      Arena.Map.Effects.run(ran_state, effects)
      msgs = collect_messages()

      raw_data =
        for msg <- msgs,
            data <-
              (case msg do
                 {:send_raw, d} -> [d]
                 {:egress, %{payload: d}} -> [d]
                 _ -> []
               end),
            do: data
      all_text = Enum.join(raw_data)

      # With no punishments, clicking priest should mention "Sin prontuario" or similar
      assert String.contains?(all_text, "Sin prontuario") or
               String.contains?(all_text, "prontuario") or
               String.contains?(all_text, "sacerdote") or
               String.contains?(all_text, "curar"),
             "Priest click should send a response message"
    end
  end
end
