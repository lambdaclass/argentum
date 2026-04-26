defmodule Arena.RewardNpcParityTest do
  @moduledoc """
  Parity tests for the /REWARD NPC request flow.

  VB6: HandleReward — player targets an enlistador NPC and requests
  faction rewards. The server checks the player's faction_score against
  rank thresholds and grants items for any newly-qualified ranks.

  This is distinct from the automatic rank-up that fires on
  handle_enlistador_click — /REWARD is a player-initiated request
  that can be issued at any time while near an enlistador.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Social

  import Arena.Test.MapStateFactory

  @npc_type_enlistador 5

  # Test NPC IDs in a high range to avoid collisions with real data
  @test_enlistador_npc_id 9950
  @test_item_reward_rank1 9960
  @test_item_reward_rank2 9961

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    # Insert a test enlistador NPC def (royal army, faccion 3)
    enlistador_def = %Arena.Data.NpcDef{
      id: @test_enlistador_npc_id,
      name: "Test Enlistador Real",
      npc_type: @npc_type_enlistador,
      faccion: 3
    }

    :ets.insert(:arena_game_data, {{:npc, @test_enlistador_npc_id}, enlistador_def})

    # Insert test item defs for reward items
    :ets.insert(:arena_game_data, {{:item, @test_item_reward_rank1}, %{
      id: @test_item_reward_rank1,
      name: "Espada Soldado",
      stackable: false,
      valor: 100,
      grh_index: 1,
      equip_slot: :weapon,
      real: true,
      caos: false,
      obj_type: 1,
      forum_id: 0,
      puntos_pesca: 0,
      elemental_tags: 0
    }})

    :ets.insert(:arena_game_data, {{:item, @test_item_reward_rank2}, %{
      id: @test_item_reward_rank2,
      name: "Escudo Caballero",
      stackable: false,
      valor: 200,
      grh_index: 2,
      equip_slot: :shield,
      real: true,
      caos: false,
      obj_type: 1,
      forum_id: 0,
      puntos_pesca: 0,
      elemental_tags: 0
    }})

    # Seed faction ranks
    :ets.insert(:arena_game_data, {{:faction_ranks, :royal_army}, [
      %{rank: 1, required_level: 25, required_score: 100, title: "Soldado"},
      %{rank: 2, required_level: 30, required_score: 500, title: "Caballero"}
    ]})

    # Seed faction rewards
    :ets.insert(:arena_game_data, {{:faction_rewards, :royal_army}, [
      %{rank: 1, obj_index: @test_item_reward_rank1},
      %{rank: 2, obj_index: @test_item_reward_rank2}
    ]})

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @test_enlistador_npc_id})
      :ets.delete(:arena_game_data, {:item, @test_item_reward_rank1})
      :ets.delete(:arena_game_data, {:item, @test_item_reward_rank2})
    end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides \\ %{}) do
    Map.merge(
      %{
        char_id: :player,
        name: "Tester",
        account_id: "acc_test",
        x: 50,
        y: 50,
        heading: :south,
        body_id: 1,
        base_body_id: 1,
        head_id: 1,
        hp: 100,
        max_hp: 100,
        mana: 200,
        max_mana: 200,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 30,
        xp: 0,
        class: :warrior,
        race: :human,
        gender: :male,
        str: 18,
        agi: 18,
        int: 18,
        con: 18,
        cha: 18,
        gold: 1000,
        inventory: List.duplicate(nil, 24),
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
        skills: %{magic: 80},
        spells: [1],
        buffs: [],
        min_hit: 0,
        max_hit: 0,
        str_buff: 0,
        agi_buff: 0,
        dead: false,
        poisoned: false,
        criminal: false,
        invisible: false,
        oculto: false,
        oculto_timer: 0,
        no_detectable: false,
        paralyzed: false,
        immobilized: false,
        meditating: false,
        resting: false,
        safe_mode: false,
        navigating: false,
        gm: false,
        faction: :none,
        next_move_at: -1_000_000_000_000,
        next_attack_at: -1_000_000_000_000,
        next_spell_at: -1_000_000_000_000,
        next_item_use_at: -1_000_000_000_000,
        spell_cooldowns: %{},
        char_index: 1,
        map_id: 1,
        npcs_killed: 0,
        deaths: 0,
        penalty: 0,
        skill_points: 0,
        home_city: :ullathorpe,
        faction_kills_royal: 0,
        faction_kills_chaos: 0,
        citizens_killed: 0,
        criminals_killed: 0,
        faction_score: 0,
        faction_rank_armada: 0,
        faction_rank_chaos: 0,
        faction_reenlistadas: 0,
        fishing_points: 0,
        last_step_at: -1_000_000_000_000,
        speed_hack_counter: 0.0,
        speeding: 1.0,
        commerce_npc_id: nil,
        bank_npc_id: nil,
        bank_gold: 0,
        trade_request_target: nil,
        trade_partner_id: nil,
        trade_offer_gold: 0,
        trade_offer_items: [],
        trade_accepted: false,
        pet_ids: [],
        description: "",
        muted_until: 0,
        last_chat_at: -1_000_000_000_000,
        spouse_id: 0,
        marriage_proposal_target: nil,
        in_duel: false,
        duel_opponent_id: nil,
        gamble_wins: 0,
        gamble_losses: 0,
        gamble_plays: 0,
        active_quests: [],
        completed_quests: MapSet.new(),
        quest_npc_id: nil,
        mounted: false,
        saddle_obj_index: 0,
        saddle_slot: 0
      },
      overrides
    )
  end

  defp make_map_state(player, npcs_live, opts \\ []) do
    map_state(
      players: %{player: player},
      sessions: %{player: self()},
      npcs_live: npcs_live,
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp decode_console_msg(<<37::little-signed-16, data::binary>>) do
    with {:ok, message, rest} <- AoProtocol.Reader.read_string8(data),
         {:ok, _font_index, _rest} <- AoProtocol.Reader.read_int8(rest) do
      message
    else
      _ -> flunk("Could not decode console_msg payload")
    end
  end

  defp drain_messages do
    receive do
      _ -> drain_messages()
    after
      0 -> :ok
    end
  end

  defp collect_console_messages do
    collect_console_messages([])
  end

  defp collect_console_messages(acc) do
    receive do
      {:send_raw, <<37::little-signed-16, _::binary>> = raw} ->
        collect_console_messages([raw | acc])

      _ ->
        collect_console_messages(acc)
    after
      10 -> Enum.reverse(acc)
    end
  end

  # Pull console_msg packets (id 37) out of an effect list.
  defp console_payloads(effects) do
    Enum.flat_map(effects, fn
      {:send, _char_id, %{payload: <<37::little-signed-16, _::binary>> = raw}} -> [raw]
      _ -> []
    end)
  end

  defp first_console_payload(effects) do
    case console_payloads(effects) do
      [first | _] -> first
      [] -> nil
    end
  end

  # Combine console_msg payloads from effects (post-Social-migration) and
  # from the test pid's mailbox (Faction.handle_faction_rank_up still uses
  # the legacy `Helpers.msg/3` shim that sends `{:send_raw, _}`). The
  # rank-up message-text assertions below need both shapes until Faction
  # migrates.
  defp all_console_payloads(effects) do
    legacy =
      collect_console_messages()

    console_payloads(effects) ++ legacy
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. Player qualifies for rank 1 -- reward items are granted
  # ═══════════════════════════════════════════════════════════════════════════

  describe "reward NPC grants items for qualifying rank" do
    test "player with enough score for rank 1 receives rank-up and reward items" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          level: 30,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, _effects} = Social.handle_request_reward(state, :player)
      drain_messages()

      updated = new_state.players[:player]

      # Should have been promoted to rank 1
      assert updated.faction_rank_armada == 1

      # Should have the rank 1 reward item in inventory
      has_rank1_item =
        Enum.any?(updated.inventory, fn
          %{item_id: id} when id == @test_item_reward_rank1 -> true
          _ -> false
        end)

      assert has_rank1_item, "Player should have received rank 1 reward item"
    end

    test "player qualifying for rank 2 receives both rank-up and rewards" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 1,
          faction_score: 600,
          level: 30,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, _effects} = Social.handle_request_reward(state, :player)
      drain_messages()

      updated = new_state.players[:player]

      # Should have been promoted to rank 2
      assert updated.faction_rank_armada == 2

      # Should have the rank 2 reward item
      has_rank2_item =
        Enum.any?(updated.inventory, fn
          %{item_id: id} when id == @test_item_reward_rank2 -> true
          _ -> false
        end)

      assert has_rank2_item, "Player should have received rank 2 reward item"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. Player already at max rank -- no more rewards
  # ═══════════════════════════════════════════════════════════════════════════

  describe "no rewards when already at max rank" do
    test "player at highest rank gets rejection message" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 2,
          faction_score: 10000,
          level: 45,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      # Should receive a message about max rank (currently emitted via
      # Faction.handle_faction_rank_up's legacy `msg/3` shim — collect
      # both effects and `{:send_raw, _}` mailbox messages).
      payloads = all_console_payloads(effects)
      assert payloads != [], "expected console message"
      msg = Enum.map(payloads, &decode_console_msg/1) |> Enum.join(" ")
      assert msg =~ "maximo" or msg =~ "recompensa"

      # Rank should remain unchanged
      assert new_state.players[:player].faction_rank_armada == 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. Insufficient score -- told how many points missing
  # ═══════════════════════════════════════════════════════════════════════════

  describe "insufficient faction score" do
    test "player without enough score is told how many points are missing" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 1,
          faction_score: 200,
          level: 30,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      # Should receive message about missing points (Faction-emitted via
      # legacy `msg/3` shim).
      payloads = all_console_payloads(effects)
      assert payloads != [], "expected console message"
      msg = Enum.map(payloads, &decode_console_msg/1) |> Enum.join(" ")
      assert msg =~ "300" or msg =~ "puntos"

      # Rank should NOT change
      assert new_state.players[:player].faction_rank_armada == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. Insufficient level -- told how many levels missing
  # ═══════════════════════════════════════════════════════════════════════════

  describe "insufficient level" do
    test "player without enough level is told how many levels are missing" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 1,
          faction_score: 600,
          level: 28,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      # Should receive message about missing levels (Faction-emitted via
      # legacy `msg/3` shim).
      payloads = all_console_payloads(effects)
      assert payloads != [], "expected console message"
      msg = Enum.map(payloads, &decode_console_msg/1) |> Enum.join(" ")
      assert msg =~ "nivel" or msg =~ "2"

      # Rank should NOT change
      assert new_state.players[:player].faction_rank_armada == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. Guard rails -- dead, no faction, wrong NPC, too far
  # ═══════════════════════════════════════════════════════════════════════════

  describe "guard rails" do
    test "dead player cannot request reward" do
      entity =
        make_entity(%{
          dead: true,
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "muerto"
      refute_receive {:send_raw, _}, 50

      # No rank change
      assert new_state.players[:player].faction_rank_armada == 0
    end

    test "factionless player cannot request reward" do
      entity =
        make_entity(%{
          faction: :none,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, _state, effects} = Social.handle_request_reward(state, :player)

      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "faccion"
      refute_receive {:send_raw, _}, 50
    end

    test "player too far from enlistador is rejected" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 60, y: 60, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "lejos"
      refute_receive {:send_raw, _}, 50

      assert new_state.players[:player].faction_rank_armada == 0
    end

    test "no selected NPC is rejected" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150
        })

      state = make_map_state(entity, %{})

      {:ok, _state, effects} = Social.handle_request_reward(state, :player)

      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "seleccionar"
      refute_receive {:send_raw, _}, 50
    end

    test "non-enlistador NPC is rejected" do
      # Insert a banker NPC def
      banker_def = %Arena.Data.NpcDef{
        id: 9951,
        name: "Test Banker",
        npc_type: 4,
        faccion: 0
      }

      :ets.insert(:arena_game_data, {{:npc, 9951}, banker_def})

      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          last_clicked_npc_instance_id: :banker,
          last_clicked_npc_type: 4
        })

      banker = %{npc_id: 9951, x: 51, y: 50, instance_id: :banker}
      state = make_map_state(entity, %{banker: banker})

      {:ok, _state, effects} = Social.handle_request_reward(state, :player)

      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "seleccionar"
      refute_receive {:send_raw, _}, 50

      :ets.delete(:arena_game_data, {:npc, 9951})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5b. Wrong-side enlistador -- VB6: Protocol.bas:4618 checks faction match
  # ═══════════════════════════════════════════════════════════════════════════

  describe "wrong-side enlistador rejected (VB6 faction-side check)" do
    test "royal army player cannot claim rewards from chaos enlistador" do
      # Create a Chaos Legion enlistador (faccion 2)
      chaos_enlistador_def = %Arena.Data.NpcDef{
        id: 9952,
        name: "Test Enlistador Caos",
        npc_type: @npc_type_enlistador,
        faccion: 2
      }

      :ets.insert(:arena_game_data, {{:npc, 9952}, chaos_enlistador_def})

      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          level: 30,
          last_clicked_npc_instance_id: :chaos_enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: 9952, x: 51, y: 50, instance_id: :chaos_enlistador}
      state = make_map_state(entity, %{chaos_enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      # Should NOT promote -- wrong faction side
      assert new_state.players[:player].faction_rank_armada == 0

      # Should receive rejection message
      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "faccion" or msg =~ "enlistador"
      refute_receive {:send_raw, _}, 50

      :ets.delete(:arena_game_data, {:npc, 9952})
    end

    test "chaos legion player cannot claim rewards from royal army enlistador" do
      # The test setup already has a royal army enlistador (faccion 3)
      entity =
        make_entity(%{
          faction: :chaos_legion,
          faction_rank_chaos: 0,
          faction_score: 150,
          level: 30,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      # Should NOT promote -- wrong faction side
      assert new_state.players[:player].faction_rank_chaos == 0

      # Should receive rejection message
      raw = first_console_payload(effects)
      assert raw, "expected console message effect"
      msg = decode_console_msg(raw)
      assert msg =~ "faccion" or msg =~ "enlistador"
      refute_receive {:send_raw, _}, 50
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. Rank-up message is sent to the player
  # ═══════════════════════════════════════════════════════════════════════════

  describe "rank-up notification" do
    test "player receives rank-up message with new rank title" do
      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          level: 30,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, _new_state, effects} = Social.handle_request_reward(state, :player)

      # The rank-up text comes from Faction.handle_faction_rank_up via the
      # legacy `msg/3` shim, so we must collect both effects and
      # `{:send_raw, _}` mailbox messages here.
      texts = effects |> all_console_payloads() |> Enum.map(&decode_console_msg/1)

      # Should have a message mentioning the rank or title
      has_rank_msg =
        Enum.any?(texts, fn text ->
          String.contains?(text, "Soldado") or String.contains?(text, "rango")
        end)

      assert has_rank_msg, "Expected rank-up notification, got: #{inspect(texts)}"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 7. Reward with full inventory -- player is told no space
  # ═══════════════════════════════════════════════════════════════════════════

  describe "full inventory handling" do
    test "player with full inventory gets no-space message but still ranks up" do
      # Fill all 24 slots with dummy items
      full_inv =
        for _ <- 1..24 do
          %{item_id: 37, amount: 1, equipped: false, elemental_tags: 0}
        end

      entity =
        make_entity(%{
          faction: :royal_army,
          faction_rank_armada: 0,
          faction_score: 150,
          level: 30,
          inventory: full_inv,
          last_clicked_npc_instance_id: :enlistador,
          last_clicked_npc_type: @npc_type_enlistador
        })

      # Make sure item 37 is non-stackable so slots are truly full
      :ets.insert(:arena_game_data, {{:item, 37}, %{
        id: 37, name: "Dummy", stackable: false, valor: 1,
        grh_index: 1, equip_slot: nil, real: false, caos: false,
        obj_type: 1, forum_id: 0, puntos_pesca: 0, elemental_tags: 0
      }})

      enlistador = %{npc_id: @test_enlistador_npc_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(entity, %{enlistador: enlistador})

      {:ok, new_state, effects} = Social.handle_request_reward(state, :player)

      # The no-space message comes from Faction.give_faction_rewards via
      # the legacy `msg/3` shim — collect both effects and mailbox.
      texts = effects |> all_console_payloads() |> Enum.map(&decode_console_msg/1)

      # Should be ranked up even if inventory is full
      assert new_state.players[:player].faction_rank_armada == 1

      # Should have a no-space message
      has_no_space =
        Enum.any?(texts, fn text ->
          String.contains?(text, "espacio")
        end)

      assert has_no_space, "Expected no-space message, got: #{inspect(texts)}"

      :ets.delete(:arena_game_data, {:item, 37})
    end
  end
end
