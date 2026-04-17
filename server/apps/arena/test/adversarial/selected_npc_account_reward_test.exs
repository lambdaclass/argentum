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

  defp make_map_state(player, npcs_live) do
    map_state(
      players: %{player: player},
      sessions: %{player: self()},
      npcs_live: npcs_live,
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
         {:ok, font_index, _rest} <- Reader.read_int8(rest) do
      %{message: message, font_index: font_index}
    else
      _ -> flunk("Could not decode console_msg payload")
    end
  end

  describe "request_account_state requires selected NPC semantics" do
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

    test "nearby timbero alone should not expose gambling stats" do
      timbero_id = find_npc_id_by_type(6)
      assert timbero_id != nil

      timbero = %{npc_id: timbero_id, x: 51, y: 50, instance_id: :timbero}
      state = make_map_state(make_entity(%{gamble_wins: 20, gamble_losses: 3}), %{timbero: timbero})

      assert {:noreply, _state} = Social.handle_request_account_state(state, :player)

      assert_receive {:send_raw, raw}
      msg = decode_console_msg(raw)
      assert msg.message =~ "seleccionar"
      refute msg.message =~ "Ganancias"
    end
  end

  describe "request_reward requires selected NPC semantics" do
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
  end
end
