defmodule Arena.NpcTextParityTest do
  @moduledoc """
  VB6 parity tests for NPC response text and values.

  ROADMAP #6: Match timbero account-state counters and values to VB6.
  ROADMAP #10: Match banker, timbero, priest, and enlistador response text/values to VB6.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.{Social, NpcInteraction}
  alias AoProtocol.Reader

  import Arena.Test.MapStateFactory

  @npc_type_timbero 10

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp make_entity(overrides) do
    defaults = %{
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
      level: 25,
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
    }

    Map.merge(defaults, overrides)
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

  defp find_npc_id_by_type(type) do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{npc_type: ^type} -> id
        _ -> nil
      end
    end)
  end

  defp decode_console_msg(<<37::little-signed-16, data::binary>>) do
    with {:ok, message, rest} <- Reader.read_string8(data),
         {:ok, _font_index, _rest} <- Reader.read_int8(rest) do
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

  defp collect_console_messages(count \\ 10) do
    Enum.reduce_while(1..count, [], fn _, acc ->
      receive do
        {:send_raw, <<37::little-signed-16, _::binary>> = raw} ->
          {:cont, [decode_console_msg(raw) | acc]}

        {:egress, %{payload: <<37::little-signed-16, _::binary>> = raw}} ->
          {:cont, [decode_console_msg(raw) | acc]}

        {:send_raw, _} ->
          {:cont, acc}

        {:egress, _} ->
          {:cont, acc}
      after
        50 -> {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Timbero account state — VB6 parity (ROADMAP #6)
  #
  # VB6: HandleRequestAccountState for Timbero shows three separate stats:
  #   - "Apuestas ganadas: <count>"
  #   - "Apuestas perdidas: <count>"
  #   - "Veces jugadas: <count>"
  #
  # Current code wrongly computes `wins - losses` as if they were gold
  # amounts and shows a single "Ganancias" line.
  # ══════════════════════════════════════════════════════════════════════════

  describe "timbero account-state (VB6 parity)" do
    test "shows gamble_wins, gamble_losses, and gamble_plays separately" do
      timbero_id = find_npc_id_by_type(10)
      assert timbero_id != nil

      timbero = %{npc_id: timbero_id, x: 51, y: 50, instance_id: :timbero}
      entity = make_entity(%{
        gamble_wins: 7,
        gamble_losses: 3,
        gamble_plays: 10,
        last_clicked_npc_instance_id: :timbero,
        last_clicked_npc_type: @npc_type_timbero
      })
      state = make_map_state(entity, %{timbero: timbero})

      assert {:ok, _state, effects} = Social.handle_request_account_state(state, :player)

      messages =
        for {:send, _char_id, %{payload: <<37::little-signed-16, _::binary>> = raw}} <- effects do
          decode_console_msg(raw)
        end

      all_text = Enum.join(messages, " ")

      # VB6: must report individual counters, not a computed "earnings" number
      assert all_text =~ "7", "should contain wins count (7)"
      assert all_text =~ "3", "should contain losses count (3)"
      assert all_text =~ "10", "should contain plays count (10)"
      # Must NOT show the old wrong "Ganancias" computation (7 - 3 = 4)
      refute all_text =~ "Ganancias"
      refute_receive {:send_raw, _}, 50
      refute_receive {:egress, _}, 50
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Timbero gamble messages — use NPC name, not hardcoded "Timbero"
  # ══════════════════════════════════════════════════════════════════════════

  describe "timbero gamble win/loss message uses NPC name from definition" do
    test "win message includes NPC definition name, not hardcoded 'Timbero'" do
      timbero_id = find_npc_id_by_type(10)
      assert timbero_id != nil
      npc_def = GameData.get_npc(timbero_id)

      timbero = %{npc_id: timbero_id, x: 51, y: 50, instance_id: :timbero}

      # Seed :rand deterministically so we always sample both win and loss
      # outcomes over the trial window. handle_gamble/4 runs synchronously in
      # the test process, so the per-process seed applies.
      :rand.seed(:exsss, {100, 200, 300})

      win_msgs = []
      loss_msgs = []

      {win_msgs, loss_msgs} =
        Enum.reduce(1..40, {win_msgs, loss_msgs}, fn _, {wins, losses} ->
          # Reset entity gold each iteration to avoid running out
          fresh_entity =
            make_entity(%{
              gold: 5000,
              gamble_wins: 0,
              gamble_losses: 0,
              gamble_plays: 0,
              last_clicked_npc_instance_id: :timbero,
              last_clicked_npc_type: 10
            })
          fresh_state = make_map_state(fresh_entity, %{timbero: timbero})
          drain_messages()

          {:ok, ran_st, effects} = NpcInteraction.handle_gamble(fresh_state, :player, 100, nil)
          Arena.Map.Effects.run(ran_st, effects)

          msgs = collect_console_messages()
          win_found = Enum.find(msgs, &String.contains?(&1, "ganado"))
          loss_found = Enum.find(msgs, &String.contains?(&1, "perdido"))

          wins = if win_found, do: [win_found | wins], else: wins
          losses = if loss_found, do: [loss_found | losses], else: losses
          {wins, losses}
        end)

      # We should have collected at least one win and one loss
      assert win_msgs != [], "Expected at least one win message in 40 trials"
      assert loss_msgs != [], "Expected at least one loss message in 40 trials"

      # VB6: should use NPC definition name as prefix, e.g. "El Timbero te dice:"
      for msg <- win_msgs do
        assert msg =~ "#{npc_def.name} te dice:",
               "Win message should use NPC name '#{npc_def.name}', got: #{msg}"
      end

      for msg <- loss_msgs do
        assert msg =~ "#{npc_def.name} te dice:",
               "Loss message should use NPC name '#{npc_def.name}', got: #{msg}"
      end
    end
  end
end
