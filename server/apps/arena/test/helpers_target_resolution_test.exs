defmodule Arena.Map.HelpersTargetResolutionTest do
  use ExUnit.Case, async: false

  alias Arena.Map.Helpers

  @banker_npc_id 990_001
  @timbero_npc_id 990_002

  setup do
    if :ets.whereis(:arena_game_data) == :undefined do
      :ets.new(:arena_game_data, [:named_table, :set, :public])
    end

    :ets.insert(:arena_game_data, {
      {:npc, @banker_npc_id},
      %{id: @banker_npc_id, npc_id: @banker_npc_id, name: "Banquero", npc_type: 4, quest_numbers: []}
    })

    :ets.insert(:arena_game_data, {
      {:npc, @timbero_npc_id},
      %{id: @timbero_npc_id, npc_id: @timbero_npc_id, name: "Timbero", npc_type: 6, quest_numbers: []}
    })

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @banker_npc_id})
      :ets.delete(:arena_game_data, {:npc, @timbero_npc_id})
    end)

    :ok
  end

  test "vb6_distancia uses Manhattan distance" do
    assert Helpers.vb6_distancia_xy(10, 10, 13, 13) == 6
    assert Helpers.vb6_distancia(%{x: 10, y: 10}, %{x: 13, y: 13}) == 6
    assert Helpers.within_vb6_distance?(%{x: 10, y: 10}, %{x: 13, y: 13}, 6)
    refute Helpers.within_vb6_distance?(%{x: 10, y: 10}, %{x: 13, y: 13}, 5)
  end

  test "selected_npc returns stale selection when the instance is gone" do
    state = %{npcs_live: %{}}
    entity = %{last_clicked_npc_instance_id: :missing}

    assert Helpers.selected_npc(state, entity) == {:error, :stale_selection}
  end

  test "resolve_selected_npc enforces type and VB6 distance" do
    state = %{
      npcs_live: %{
        :banker => %{npc_id: @banker_npc_id, x: 12, y: 10}
      }
    }

    near_entity = %{x: 10, y: 10, last_clicked_npc_instance_id: :banker}
    far_entity = %{x: 10, y: 10, last_clicked_npc_instance_id: :banker}

    assert {:ok, _npc, npc_def} = Helpers.resolve_selected_npc(state, near_entity, [4], 2)
    assert npc_def.npc_type == 4

    assert :not_found = Helpers.resolve_selected_npc(state, far_entity, [6], 2)
    assert :not_found = Helpers.resolve_selected_npc(state, far_entity, [4], 1)
  end

  test "resolve_nearby_npc uses VB6 distance instead of square range" do
    state = %{
      npcs_live: %{
        :banker => %{npc_id: @banker_npc_id, x: 13, y: 13},
        :timbero => %{npc_id: @timbero_npc_id, x: 11, y: 10}
      }
    }

    entity = %{x: 10, y: 10}

    assert :not_found = Helpers.resolve_nearby_npc(state, entity, [4], 4)
    assert {:ok, _npc, npc_def} = Helpers.resolve_nearby_npc(state, entity, [6], 1)
    assert npc_def.npc_type == 6
  end
end
