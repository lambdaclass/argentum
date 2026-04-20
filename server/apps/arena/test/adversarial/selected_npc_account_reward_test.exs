defmodule Arena.Adversarial.SelectedNpcAccountRewardTest do
  @moduledoc """
  Adversarial tests for account-state and reward flows that should require
  an explicitly selected NPC, not just any nearby matching NPC.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Social
  alias AoProtocol.Reader

  import Arena.Test.MapStateFactory

  @npc_type_banquero 4
  @npc_type_enlistador 5
  @npc_type_timbero 10

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp make_entity(overrides \\ %{}) do
    Map.merge(
      %{
        char_id: :player,
        x: 50,
        y: 50,
        dead: false,
        bank_gold: 777,
        gamble_wins: 12,
        gamble_losses: 5,
        faction: :royal_army
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

  defp find_npc_id_by_type(type) do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{npc_type: ^type} -> id
        _ -> nil
      end
    end)
  end

  defp find_npc_id_not_in_types(types) do
    Enum.find_value(1..4000, fn id ->
      case GameData.get_npc(id) do
        nil ->
          nil

        npc_def ->
          if npc_def.npc_type not in types and not Map.get(npc_def, :comercia, false) do
            id
          else
            nil
          end
      end
    end)
  end

  defp decode_console_msg(<<37::little-signed-16, data::binary>>) do
    with {:ok, message, rest} <- Reader.read_string8(data),
         {:ok, font_index, _rest} <- Reader.read_int8(rest) do
      %{message: message, font_index: font_index}
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

  describe "request_account_state requires selected NPC semantics" do
    test "clicking a non-special NPC updates remembered selection and rejects account-state" do
      npc_id = find_npc_id_not_in_types([1, 3, 4, 5, 6, 9, 10, 16, 17, 20])
      assert npc_id != nil

      npc_def = GameData.get_npc(npc_id)
      npc = %{npc_id: npc_id, x: 51, y: 50, instance_id: :generic_npc}
      state = make_map_state(make_entity(%{}), %{generic_npc: npc}, occupancy: %{{51, 50} => {:npc, :generic_npc}})

      assert {:noreply, clicked_state} = Arena.Map.NpcInteraction.handle_double_click(state, :player, 51, 50)
      assert clicked_state.players[:player].last_clicked_npc_instance_id == :generic_npc
      assert clicked_state.players[:player].last_clicked_npc_type == npc_def.npc_type

      drain_messages()

      assert {:noreply, _state} = Social.handle_request_account_state(clicked_state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
    end

    test "selected banker on the same tile exposes the bank balance" do
      banker_id = find_npc_id_by_type(4)
      assert banker_id != nil

      banker = %{npc_id: banker_id, x: 51, y: 50, instance_id: :banker}
      entity = make_entity(%{bank_gold: 777, last_clicked_npc_instance_id: :banker, last_clicked_npc_type: @npc_type_banquero})
      state = make_map_state(entity, %{banker: banker})

      assert {:noreply, _state} = Social.handle_request_account_state(state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "777"
    end

    test "nearby banker alone should not expose bank balance" do
      banker_id = find_npc_id_by_type(4)
      assert banker_id != nil

      banker = %{npc_id: banker_id, x: 51, y: 50, instance_id: :banker}
      state = make_map_state(make_entity(%{bank_gold: 777}), %{banker: banker})

      assert {:noreply, _state} = Social.handle_request_account_state(state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
      refute msg.message =~ "777"
    end

    test "stale banker selection is rejected after the NPC disappears" do
      banker_id = find_npc_id_by_type(4)
      assert banker_id != nil

      banker = %{npc_id: banker_id, x: 51, y: 50, instance_id: :banker}
      stale_state =
        make_map_state(
          make_entity(%{bank_gold: 777, last_clicked_npc_instance_id: :banker, last_clicked_npc_type: @npc_type_banquero}),
          %{banker: banker}
        )
        |> Map.put(:npcs_live, %{})

      assert {:noreply, _state} = Social.handle_request_account_state(stale_state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
    end

    test "nearby timbero alone should not expose gambling stats" do
      timbero_id = find_npc_id_by_type(10)
      assert timbero_id != nil

      timbero = %{npc_id: timbero_id, x: 51, y: 50, instance_id: :timbero}
      state = make_map_state(make_entity(%{gamble_wins: 20, gamble_losses: 3}), %{timbero: timbero})

      assert {:noreply, _state} = Social.handle_request_account_state(state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
      refute msg.message =~ "Ganancias"
    end

    test "selected timbero must still be in range to expose gambling stats" do
      timbero_id = find_npc_id_by_type(10)
      assert timbero_id != nil

      timbero = %{npc_id: timbero_id, x: 51, y: 50, instance_id: :timbero}
      clicked_state =
        make_map_state(
          make_entity(%{gamble_wins: 20, gamble_losses: 3, last_clicked_npc_instance_id: :timbero, last_clicked_npc_type: @npc_type_timbero}),
          %{timbero: timbero}
        )

      far_timbero = %{timbero | x: 60, y: 50}
      far_state = %{clicked_state | npcs_live: %{timbero: far_timbero}}

      assert {:noreply, _state} = Social.handle_request_account_state(far_state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "demasiado lejos"
    end
  end

  describe "request_reward requires selected NPC semantics" do
    test "spoofed selected-NPC data cannot bypass the enlistador check" do
      wrong_npc_id = find_npc_id_not_in_types([1, 3, 4, 5, 6, 9, 10, 16, 17, 20])
      assert wrong_npc_id != nil

      fake_npc = %{npc_id: wrong_npc_id, x: 51, y: 50, instance_id: :merchant_like}
      state =
        make_map_state(
          make_entity(%{
            faction: :royal_army,
            last_clicked_npc_instance_id: :merchant_like,
            last_clicked_npc_type: 4
          }),
          %{merchant_like: fake_npc},
          occupancy: %{{51, 50} => {:npc, :merchant_like}}
        )

      assert {:noreply, _state} = Social.handle_request_reward(state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
    end

    test "nearby enlistador alone should not satisfy the reward flow" do
      enlistador_id = find_npc_id_by_type(5)
      assert enlistador_id != nil

      enlistador = %{npc_id: enlistador_id, x: 51, y: 50, instance_id: :enlistador}
      state = make_map_state(make_entity(%{faction: :royal_army}), %{enlistador: enlistador})

      assert {:noreply, _state} = Social.handle_request_reward(state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
      refute msg.message =~ "recompensas"
    end

    test "selected enlistador must still be in range to receive reward" do
      enlistador_id = find_npc_id_by_type(5)
      assert enlistador_id != nil

      enlistador = %{npc_id: enlistador_id, x: 51, y: 50, instance_id: :enlistador}
      state =
        make_map_state(
          make_entity(%{
            faction: :royal_army,
            last_clicked_npc_instance_id: :enlistador,
            last_clicked_npc_type: @npc_type_enlistador
          }),
          %{enlistador: enlistador},
          occupancy: %{{51, 50} => {:npc, :enlistador}}
        )

      far_enlistador = %{enlistador | x: 60, y: 50}
      far_state = %{state | npcs_live: %{enlistador: far_enlistador}}

      assert {:noreply, _state} = Social.handle_request_reward(far_state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "demasiado lejos"
    end
  end
end
