defmodule Arena.WalkAwayParityTest do
  @moduledoc """
  VB6 parity: commerce and bank sessions close when the player walks away
  from the NPC (ROADMAP #3-4). Also tests that double-clicking a merchant NPC
  opens a commerce session directly.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.{Commerce, NpcInteraction, Movement, Bank}
  alias AoProtocol.Server.Encoder

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides \\ %{}) do
    Map.merge(
      %{
        char_id: :player,
        char_index: 1,
        x: 50,
        y: 50,
        dead: false,
        gold: 50_000,
        commerce_npc_id: nil,
        commerce_npc_instance_id: nil,
        bank_npc_id: nil,
        bank_gold: 0,
        inventory: List.duplicate(nil, 24),
        heading: :south,
        last_step_at: 0,
        next_move_at: 0,
        speed_hack_counter: 0.0,
        speeding: 1.0,
        resting: false,
        meditating: false,
        navigating: false,
        paralyzed: false,
        immobilized: false,
        invisible: false,
        oculto: false,
        oculto_timer: 0,
        gm: false,
        penalty: 0,
        trade_partner_id: nil,
        last_clicked_npc_instance_id: nil,
        last_clicked_npc_type: nil,
        active_quests: [],
        skills: %{},
        class: :guerrero,
        level: 10
      },
      overrides
    )
  end

  defp make_merchant_npc(x, y) do
    npc_id = find_merchant_npc_id()
    %{npc_id: npc_id, x: x, y: y, instance_id: :merch_1}
  end

  defp make_banker_npc(x, y) do
    npc_id = find_banker_npc_id()
    %{npc_id: npc_id, x: x, y: y, instance_id: :banker_1}
  end

  defp make_map_state(player, opts \\ []) do
    map_state(
      players: %{player: player},
      sessions: %{player: self()},
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false, tile_exit_map: %{}}
    )
  end

  defp find_merchant_npc_id do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{comercia: true, shop_items: [_ | _]} -> id
        _ -> nil
      end
    end)
  end

  defp find_banker_npc_id do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{npc_type: 4} -> id
        _ -> nil
      end
    end)
  end

  # ── Commerce walk-away ──────────────────────────────────────────────────

  describe "walk-away closes commerce session" do
    test "commerce session closed when player moves > 3 tiles from merchant" do
      merchant = make_merchant_npc(50, 50)

      entity =
        make_entity(%{
          x: 53,
          y: 50,
          commerce_npc_id: merchant.npc_id,
          commerce_npc_instance_id: :merch_1
        })

      state =
        make_map_state(entity,
          npcs_live: %{merch_1: merchant},
          occupancy: %{{53, 50} => {:player, :player}}
        )

      # Player is at distance 3 — session still open
      state = Movement.check_npc_session_proximity(state, :player)
      updated = state.players[:player]
      assert updated.commerce_npc_id == merchant.npc_id

      # Now move player to distance 4 (> 3)
      entity_far = %{updated | x: 54, y: 50}
      state = %{state | players: Map.put(state.players, :player, entity_far)}
      state = Movement.check_npc_session_proximity(state, :player)

      updated_far = state.players[:player]
      assert updated_far.commerce_npc_id == nil
      assert updated_far.commerce_npc_instance_id == nil

      # Client should receive commerce_end
      assert_received {:send_raw, raw}
      assert raw == Encoder.encode({:commerce_end, %{}})
    end

    test "commerce session kept when player is within 3 tiles" do
      merchant = make_merchant_npc(50, 50)

      entity =
        make_entity(%{
          x: 52,
          y: 50,
          commerce_npc_id: merchant.npc_id,
          commerce_npc_instance_id: :merch_1
        })

      state =
        make_map_state(entity,
          npcs_live: %{merch_1: merchant},
          occupancy: %{{52, 50} => {:player, :player}}
        )

      state = Movement.check_npc_session_proximity(state, :player)
      updated = state.players[:player]
      assert updated.commerce_npc_id == merchant.npc_id
    end

    test "commerce session closed when merchant NPC despawns" do
      entity =
        make_entity(%{
          x: 50,
          y: 50,
          commerce_npc_id: 123,
          commerce_npc_instance_id: :merch_gone
        })

      state =
        make_map_state(entity,
          npcs_live: %{},
          occupancy: %{{50, 50} => {:player, :player}}
        )

      state = Movement.check_npc_session_proximity(state, :player)
      updated = state.players[:player]
      assert updated.commerce_npc_id == nil
      assert updated.commerce_npc_instance_id == nil
    end
  end

  # ── Bank walk-away ──────────────────────────────────────────────────────

  describe "walk-away closes bank session" do
    test "bank session closed when player moves > 6 tiles from banker" do
      banker = make_banker_npc(50, 50)

      entity =
        make_entity(%{
          x: 56,
          y: 50,
          bank_npc_id: :banker_1
        })

      state =
        make_map_state(entity,
          npcs_live: %{banker_1: banker},
          occupancy: %{{56, 50} => {:player, :player}}
        )

      # Player at distance 6 — still open
      state = Movement.check_npc_session_proximity(state, :player)
      updated = state.players[:player]
      assert updated.bank_npc_id == :banker_1

      # Move to distance 7
      entity_far = %{updated | x: 57, y: 50}
      state = %{state | players: Map.put(state.players, :player, entity_far)}
      state = Movement.check_npc_session_proximity(state, :player)

      updated_far = state.players[:player]
      assert updated_far.bank_npc_id == nil

      assert_received {:send_raw, raw}
      assert raw == Encoder.encode({:bank_end, %{}})
    end

    test "bank session kept when player is within 6 tiles" do
      banker = make_banker_npc(50, 50)

      entity =
        make_entity(%{
          x: 55,
          y: 50,
          bank_npc_id: :banker_1
        })

      state =
        make_map_state(entity,
          npcs_live: %{banker_1: banker},
          occupancy: %{{55, 50} => {:player, :player}}
        )

      state = Movement.check_npc_session_proximity(state, :player)
      updated = state.players[:player]
      assert updated.bank_npc_id == :banker_1
    end

    test "bank session closed when banker NPC despawns" do
      entity =
        make_entity(%{
          x: 50,
          y: 50,
          bank_npc_id: :banker_gone
        })

      state =
        make_map_state(entity,
          npcs_live: %{},
          occupancy: %{{50, 50} => {:player, :player}}
        )

      state = Movement.check_npc_session_proximity(state, :player)
      updated = state.players[:player]
      assert updated.bank_npc_id == nil
    end
  end

  # ── NPC double-click opens commerce ─────────────────────────────────────

  describe "NPC double-click opens commerce" do
    test "double-clicking a merchant NPC opens commerce session" do
      merchant = make_merchant_npc(50, 50)

      entity = make_entity(%{x: 51, y: 50})

      state =
        make_map_state(entity,
          npcs_live: %{merch_1: merchant},
          occupancy: %{
            {51, 50} => {:player, :player},
            {50, 50} => {:npc, :merch_1}
          }
        )

      {:ok, new_state, _effects} = NpcInteraction.handle_double_click(state, :player, 50, 50)

      updated = new_state.players[:player]
      assert updated.commerce_npc_id == merchant.npc_id
      assert updated.commerce_npc_instance_id == :merch_1

      # Should have received commerce_init packet
      assert_received {:send_raw, _commerce_init}
    end
  end
end
