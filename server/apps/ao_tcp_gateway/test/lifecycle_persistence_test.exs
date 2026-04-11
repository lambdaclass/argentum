defmodule AoTcpGateway.LifecyclePersistenceTest do
  @moduledoc """
  Lifecycle tests for login/autosave/logout/crash-cleanup/transfer persistence.

  Exercises the full TCP flow using the same infrastructure as
  ClientHandlerIntegrationTest.
  """

  use ExUnit.Case

  alias AoProtocol.Writer
  alias AoProtocol.Reader

  @connect_timeout 2000
  @recv_timeout 500

  # ---- Infrastructure setup (mirrors ClientHandlerIntegrationTest) ----

  setup_all do
    start_if_needed(:ranch_sup, fn -> Application.ensure_all_started(:ranch) end)

    start_if_needed(Arena.PubSub, fn ->
      Application.ensure_all_started(:phoenix_pubsub)
      Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end)

    start_if_needed(AoSession.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end)

    start_if_needed(Arena.MapRegistry, fn ->
      Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end)

    start_if_needed(Arena.Map.MapSupervisor, fn ->
      Arena.Map.MapSupervisor.start_link([])
    end)

    ensure_map_started(1)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    listener_name = :"test_lifecycle_#{System.unique_integer([:positive])}"

    {:ok, _} =
      :ranch.start_listener(
        listener_name,
        :ranch_tcp,
        [port: 0],
        AoTcpGateway.ClientHandler,
        []
      )

    port = :ranch.get_port(listener_name)

    on_exit(fn -> :ranch.stop_listener(listener_name) end)

    %{port: port}
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw], @connect_timeout)

    socket
  end

  defp send_login_with_name(socket, name) do
    token = "test_token"
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(token) <>
        Writer.write_string8(name) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5) <>
        Writer.write_int8(1) <>
        Writer.write_int8(1) <>
        Writer.write_int8(6) <>
        Writer.write_int16(1) <>
        Writer.write_int8(1)

    packet = Writer.build_packet(74, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_login_existing(socket, char_id, session_token) do
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(session_token) <>
        Writer.write_int32(char_id) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5)

    packet = Writer.build_packet(73, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_walk(socket, heading) do
    payload = Writer.write_int8(heading) <> Writer.write_int32(1)
    packet = Writer.build_packet(78, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp recv_all(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :timeout} -> acc
      {:error, _reason} -> acc
    end
  end

  defp recv_until_packet(socket, target_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_until_packet_loop(socket, target_id, deadline, <<>>)
  end

  defp recv_until_packet_loop(socket, target_id, deadline, acc_data) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      decode_all_packets(acc_data)
    else
      case :gen_tcp.recv(socket, 0, min(remaining, 200)) do
        {:ok, data} ->
          all_data = acc_data <> data
          packets = decode_all_packets(all_data)

          if Enum.any?(packets, fn {id, _} -> id == target_id end) do
            Process.sleep(100)

            extra =
              case :gen_tcp.recv(socket, 0, 100) do
                {:ok, d} -> d
                {:error, _} -> <<>>
              end

            decode_all_packets(all_data <> extra)
          else
            recv_until_packet_loop(socket, target_id, deadline, all_data)
          end

        {:error, :timeout} ->
          recv_until_packet_loop(socket, target_id, deadline, acc_data)

        {:error, _reason} ->
          decode_all_packets(acc_data)
      end
    end
  end

  defp get_char_id(name) do
    case GameBackend.Characters.get_by_name(name) do
      nil -> nil
      char -> char.id
    end
  end

  defp cleanup_char(nil), do: :ok

  defp cleanup_char(char_id) do
    try do
      Arena.Map.MapServer.leave(1, char_id)
    catch
      :exit, _ -> :ok
    end

    AoSession.OnlineDirectory.unregister(char_id)
    AoSession.unregister(char_id)
  end

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end

  defp unique_name, do: "LCT_#{System.unique_integer([:positive])}"

  defp find_packet(packets, id) do
    Enum.find(packets, fn {pid, _} -> pid == id end)
  end

  defp ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    wait_map_ready(map_id, 50)
  end

  defp wait_map_ready(_map_id, 0), do: :ok

  defp wait_map_ready(map_id, retries) do
    if Arena.Map.MapServer.ready?(map_id) do
      :ok
    else
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
    end
  rescue
    _ ->
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
  catch
    :exit, _ ->
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
  end

  # Login via packet 74 (new char), return {socket, packets, char_id}
  defp login_new(port, name) do
    socket = connect(port)
    send_login_with_name(socket, name)
    data = recv_all(socket)
    packets = decode_all_packets(data)
    char_id = get_char_id(name)
    {socket, packets, char_id}
  end

  # Try walking in a direction and return {:ok, new_pos} or :blocked
  defp try_walk(socket, heading) do
    send_walk(socket, heading)
    data = recv_all(socket)
    packets = decode_all_packets(data)

    case find_packet(packets, 31) do
      {31, pos} -> {:ok, pos}
      nil -> :blocked
    end
  end

  # Walk any direction that succeeds
  defp walk_any_direction(socket) do
    Enum.find_value([3, 1, 2, 4], fn heading ->
      case try_walk(socket, heading) do
        {:ok, pos} -> {heading, pos}
        :blocked -> nil
      end
    end)
  end

  # ---- Packet decoders (same as integration test) ----

  defp decode_all_packets(data), do: decode_all_packets(data, [])
  defp decode_all_packets(<<>>, acc), do: Enum.reverse(acc)
  defp decode_all_packets(data, acc) when byte_size(data) < 2, do: Enum.reverse(acc)

  defp decode_all_packets(<<packet_id::little-signed-16, rest::binary>>, acc) do
    case decode_server_packet(packet_id, rest) do
      {:ok, fields, remaining} -> decode_all_packets(remaining, [{packet_id, fields} | acc])
      :incomplete -> Enum.reverse(acc)
    end
  end

  defp decode_server_packet(2, <<new_user::8, rest::binary>>),
    do: {:ok, %{new_user: new_user != 0}, rest}

  defp decode_server_packet(25, <<min_sta::little-signed-16, rest::binary>>),
    do: {:ok, %{min_sta: min_sta}, rest}

  defp decode_server_packet(26, <<min_mana::little-signed-16, rest::binary>>),
    do: {:ok, %{min_mana: min_mana}, rest}

  defp decode_server_packet(27, <<min_hp::little-signed-16, shield::little-signed-32, rest::binary>>),
    do: {:ok, %{min_hp: min_hp, shield: shield}, rest}

  defp decode_server_packet(28, <<gold::little-signed-32, _billetera::little-signed-32, rest::binary>>),
    do: {:ok, %{gold: gold}, rest}

  defp decode_server_packet(30, <<map_id::little-signed-16, version::little-signed-16, rest::binary>>),
    do: {:ok, %{map_id: map_id, version: version}, rest}

  defp decode_server_packet(31, <<x::8, y::8, rest::binary>>),
    do: {:ok, %{x: x, y: y}, rest}

  defp decode_server_packet(35, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, char_index, rest} <- Reader.read_int16(rest),
         {:ok, color, rest} <- Reader.read_int32(rest),
         {:ok, es_spell, rest} <- Reader.read_bool(rest),
         {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, min_time, rest} <- Reader.read_int16(rest),
         {:ok, max_time, rest} <- Reader.read_int16(rest) do
      {:ok,
       %{
         message: msg,
         char_index: char_index,
         color: color,
         es_spell: es_spell,
         x: x,
         y: y,
         min_display_time: min_time,
         max_display_time: max_time
       }, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(37, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, font, rest} <- Reader.read_int8(rest) do
      {:ok, %{message: msg, font_index: font}, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(42, data) do
    with {:ok, char_index, rest} <- Reader.read_int16(data),
         {:ok, body_id, rest} <- Reader.read_int16(rest),
         {:ok, head_id, rest} <- Reader.read_int16(rest),
         {:ok, heading, rest} <- Reader.read_int8(rest),
         {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, _weapon, rest} <- Reader.read_int16(rest),
         {:ok, _shield, rest} <- Reader.read_int16(rest),
         {:ok, _helmet, rest} <- Reader.read_int16(rest),
         {:ok, _cart, rest} <- Reader.read_int16(rest),
         {:ok, _backpack, rest} <- Reader.read_int16(rest),
         {:ok, _fx, rest} <- Reader.read_int16(rest),
         {:ok, _fx_loops, rest} <- Reader.read_int16(rest),
         {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, _status, rest} <- Reader.read_int8(rest),
         {:ok, _privileges, rest} <- Reader.read_int8(rest),
         {:ok, _particula_fx, rest} <- Reader.read_int8(rest),
         {:ok, _head_aura, rest} <- Reader.read_string8(rest),
         {:ok, _arma_aura, rest} <- Reader.read_string8(rest),
         {:ok, _body_aura, rest} <- Reader.read_string8(rest),
         {:ok, _dm_aura, rest} <- Reader.read_string8(rest),
         {:ok, _rm_aura, rest} <- Reader.read_string8(rest),
         {:ok, _otra_aura, rest} <- Reader.read_string8(rest),
         {:ok, _escudo_aura, rest} <- Reader.read_string8(rest),
         {:ok, speed, rest} <- Reader.read_real32(rest),
         {:ok, _es_npc, rest} <- Reader.read_int8(rest),
         {:ok, _appear, rest} <- Reader.read_int8(rest),
         {:ok, _group, rest} <- Reader.read_int16(rest),
         {:ok, _clan, rest} <- Reader.read_int16(rest),
         {:ok, _clan_nivel, rest} <- Reader.read_int8(rest),
         {:ok, min_hp, rest} <- Reader.read_int32(rest),
         {:ok, max_hp, rest} <- Reader.read_int32(rest),
         {:ok, min_mana, rest} <- Reader.read_int32(rest),
         {:ok, max_mana, rest} <- Reader.read_int32(rest),
         {:ok, _simbolo, rest} <- Reader.read_int8(rest),
         {:ok, _flags, rest} <- Reader.read_int8(rest),
         {:ok, _tipo_usuario, rest} <- Reader.read_int8(rest),
         {:ok, _team_captura, rest} <- Reader.read_int8(rest),
         {:ok, _tiene_bandera, rest} <- Reader.read_int8(rest),
         {:ok, _npc_num, rest} <- Reader.read_int16(rest) do
      {:ok,
       %{
         char_index: char_index,
         body_id: body_id,
         head_id: head_id,
         heading: heading,
         x: x,
         y: y,
         name: name,
         speed: speed,
         min_hp: min_hp,
         max_hp: max_hp,
         min_mana: min_mana,
         max_mana: max_mana
       }, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(43, <<char_index::little-signed-16, desvanecido::8, fue_warp::8, rest::binary>>),
    do: {:ok, %{char_index: char_index, desvanecido: desvanecido != 0, fue_warp: fue_warp != 0}, rest}

  defp decode_server_packet(44, <<char_index::little-signed-16, x::8, y::8, rest::binary>>),
    do: {:ok, %{char_index: char_index, x: x, y: y}, rest}

  defp decode_server_packet(46, <<idx::little-signed-16, rest::binary>>),
    do: {:ok, %{user_index: idx}, rest}

  defp decode_server_packet(47, <<idx::little-signed-16, rest::binary>>),
    do: {:ok, %{char_index: idx}, rest}

  defp decode_server_packet(63, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
                                   equipped::8, valor::little-float-32, puede_usar::8,
                                   elemental_tags::little-signed-32, is_bindable::8, rest::binary>>) do
    {:ok,
     %{
       slot: slot,
       obj_index: obj_index,
       amount: amount,
       equipped: equipped != 0,
       valor: valor,
       puede_usar: puede_usar,
       elemental_tags: elemental_tags,
       is_bindable: is_bindable != 0
     }, rest}
  end

  defp decode_server_packet(73, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data) do
      {:ok, %{message: msg}, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(29, <<current_xp::little-signed-32, next_xp::little-signed-32, rest::binary>>),
    do: {:ok, %{current_xp: current_xp, next_xp: next_xp}, rest}

  defp decode_server_packet(66, <<slot::8, spell_id::little-signed-16, index::little-signed-16, is_bindable::8, rest::binary>>),
    do: {:ok, %{slot: slot, spell_id: spell_id, index: index, is_bindable: is_bindable != 0}, rest}

  defp decode_server_packet(80, <<level::little-16, rest::binary>>),
    do: {:ok, %{level: level}, rest}

  defp decode_server_packet(78, <<max_thirst::8, min_thirst::8, max_hunger::8, min_hunger::8, rest::binary>>),
    do: {:ok, %{max_thirst: max_thirst, min_thirst: min_thirst, max_hunger: max_hunger, min_hunger: min_hunger}, rest}

  defp decode_server_packet(158, <<
    bow::little-signed-32, walk::little-signed-32, melee::little-signed-32,
    melee_magic::little-signed-32, magic::little-signed-32, magic_melee::little-signed-32,
    melee_use::little-signed-32, work_extract::little-signed-32, work_build::little-signed-32,
    use_item::little-signed-32, use_click::little-signed-32, drop::little-signed-32,
    rest::binary>>) do
    {:ok, %{walk: walk, bow: bow, melee: melee, magic: magic,
            melee_magic: melee_magic, magic_melee: magic_melee, melee_use: melee_use,
            work_extract: work_extract, work_build: work_build,
            use_item: use_item, use_click: use_click, drop: drop}, rest}
  end

  defp decode_server_packet(87, <<skills::binary-size(24), rest::binary>>),
    do: {:ok, %{skills: skills}, rest}

  defp decode_server_packet(200, data) do
    with {:ok, char_id, rest} <- Reader.read_int32(data),
         {:ok, token, rest} <- Reader.read_string8(rest) do
      {:ok, %{char_id: char_id, token: token}, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(49, <<_::binary-size(22), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(59, <<_::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(61, <<_::binary-size(34), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(76, <<_::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(79, <<_::binary-size(28), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(81, <<_::binary-size(5), rest::binary>>), do: {:ok, %{}, rest}

  defp decode_server_packet(_id, _rest), do: :incomplete

  # ============================================================
  # Tests
  # ============================================================

  describe "autosave on disconnect" do
    test "login, walk to new position, disconnect, verify DB has updated position", %{port: port} do
      name = unique_name()
      {socket, packets, char_id} = login_new(port, name)
      on_exit(fn -> cleanup_char(char_id) end)

      assert char_id != nil
      {31, initial_pos} = find_packet(packets, 31)

      # Walk to a new position
      result = walk_any_direction(socket)
      assert result != nil, "at least one direction should be walkable"
      {_heading, new_pos} = result

      # Verify position actually changed
      assert {new_pos.x, new_pos.y} != {initial_pos.x, initial_pos.y}

      # Disconnect (triggers cleanup save)
      :gen_tcp.close(socket)
      Process.sleep(500)

      # Verify DB has the updated position
      db_char = GameBackend.Characters.get(char_id)
      assert db_char != nil
      assert db_char.pos_x == new_pos.x
      assert db_char.pos_y == new_pos.y
    end
  end

  describe "stats persist across sessions" do
    test "HP/mana/sta/gold survive disconnect and reconnect", %{port: port} do
      name = unique_name()
      {socket1, packets1, char_id} = login_new(port, name)
      on_exit(fn -> cleanup_char(char_id) end)

      # Record stats from first session
      {27, hp1} = find_packet(packets1, 27)
      {26, mana1} = find_packet(packets1, 26)
      {25, sta1} = find_packet(packets1, 25)
      {28, gold1} = find_packet(packets1, 28)

      # Disconnect
      :gen_tcp.close(socket1)
      Process.sleep(500)

      # Reconnect via Packet 73
      token = GameBackend.Characters.get(char_id).session_token
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      # Verify same stats
      {27, hp2} = find_packet(packets2, 27)
      {26, mana2} = find_packet(packets2, 26)
      {25, sta2} = find_packet(packets2, 25)
      {28, gold2} = find_packet(packets2, 28)

      assert hp2.min_hp == hp1.min_hp
      assert mana2.min_mana == mana1.min_mana
      assert sta2.min_sta == sta1.min_sta
      assert gold2.gold == gold1.gold
    end
  end

  describe "inventory persists across sessions" do
    test "inventory slots survive disconnect and reconnect", %{port: port} do
      name = unique_name()
      {socket1, packets1, char_id} = login_new(port, name)
      on_exit(fn -> cleanup_char(char_id) end)

      inv_packets1 =
        packets1
        |> Enum.filter(fn {id, _} -> id == 63 end)
        |> Enum.sort_by(fn {_, fields} -> fields.slot end)

      # Disconnect
      :gen_tcp.close(socket1)
      Process.sleep(500)

      # Reconnect
      token = GameBackend.Characters.get(char_id).session_token
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      inv_packets2 =
        packets2
        |> Enum.filter(fn {id, _} -> id == 63 end)
        |> Enum.sort_by(fn {_, fields} -> fields.slot end)

      # Same number of inventory slots
      assert length(inv_packets2) == length(inv_packets1)

      # Same item IDs and amounts
      Enum.zip(inv_packets1, inv_packets2)
      |> Enum.each(fn {{_, s1}, {_, s2}} ->
        assert s2.slot == s1.slot
        assert s2.obj_index == s1.obj_index
        assert s2.amount == s1.amount
      end)
    end
  end

  describe "map position persists" do
    test "walk to new position, disconnect, reconnect, verify spawns at saved position", %{port: port} do
      name = unique_name()
      {socket1, packets1, char_id} = login_new(port, name)
      on_exit(fn -> cleanup_char(char_id) end)

      {31, initial_pos} = find_packet(packets1, 31)

      # Walk to a new position
      result = walk_any_direction(socket1)
      assert result != nil, "at least one direction should be walkable"
      {_heading, walked_pos} = result

      assert {walked_pos.x, walked_pos.y} != {initial_pos.x, initial_pos.y}

      # Disconnect
      :gen_tcp.close(socket1)
      Process.sleep(500)

      # Reconnect via Packet 73
      token = GameBackend.Characters.get(char_id).session_token
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      # Verify position matches where we walked to
      {31, reconnect_pos} = find_packet(packets2, 31)
      assert reconnect_pos.x == walked_pos.x
      assert reconnect_pos.y == walked_pos.y
    end
  end

  describe "crash cleanup" do
    test "killing session process removes character from map and unregisters session", %{port: port} do
      name = unique_name()
      {socket, _packets, char_id} = login_new(port, name)
      on_exit(fn -> cleanup_char(char_id) end)

      assert char_id != nil

      # Verify session is registered
      assert {:ok, session_pid, _meta} = AoSession.lookup(char_id)

      # Verify player is on the map
      assert {:ok, _entity} = Arena.Map.MapServer.snapshot_entity(1, char_id)

      # Kill the session process (simulate crash)
      Process.exit(session_pid, :kill)
      Process.sleep(500)

      # Close the socket (may already be dead)
      :gen_tcp.close(socket)

      # Verify session is unregistered
      assert {:error, :not_found} = AoSession.lookup(char_id)

      # Verify player is removed from map
      assert {:error, :not_on_map} = Arena.Map.MapServer.snapshot_entity(1, char_id)
    end
  end

  describe "map transfer persistence" do
    # This scenario is also tested in client_handler_integration_test.exs
    # ("transfer preserves entity state on reconnect"), but we include a
    # focused version here for completeness.

    defp all_exits_with_approach(exits) do
      approaches = [
        {0, -1, 3},
        {0, 1, 1},
        {-1, 0, 2},
        {1, 0, 4}
      ]

      Enum.flat_map(exits, fn ex ->
        Enum.flat_map(approaches, fn {dx, dy, heading} ->
          sx = ex.x + dx
          sy = ex.y + dy

          if sx >= 1 and sx <= 100 and sy >= 1 and sy <= 100 and
               TileGrid.is_walkable(1, ex.x, ex.y) and
               TileGrid.is_walkable(1, sx, sy) do
            [{ex, {sx, sy}, heading}]
          else
            []
          end
        end)
      end)
    end

    test "transfer to new map persists across disconnect/reconnect", %{port: port} do
      map_data = Arena.Map.MapServer.get_map_data(1)
      exits_with_approach = all_exits_with_approach(map_data.exits)
      assert exits_with_approach != [], "need at least one reachable exit on map 1"

      result =
        Enum.find_value(exits_with_approach, :no_exit_worked, fn {exit_tile, {sx, sy}, heading} ->
          ensure_map_started(exit_tile.dest_map)

          name = unique_name()
          {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")

          {:ok, character} =
            GameBackend.Characters.create(%{
              name: name,
              account_id: account.id,
              map_id: 1,
              pos_x: sx,
              pos_y: sy,
              heading: "south"
            })

          socket = connect(port)
          send_login_existing(socket, character.id, character.session_token)
          login_data = recv_all(socket)
          login_packets = decode_all_packets(login_data)

          {31, login_pos} = find_packet(login_packets, 31)

          if login_pos.x == sx and login_pos.y == sy do
            {:ok, socket, character.id, character.session_token, exit_tile, heading}
          else
            :gen_tcp.close(socket)
            cleanup_char(character.id)
            nil
          end
        end)

      assert result != :no_exit_worked,
        "no exit had a free approach tile"

      {:ok, socket, char_id, token, exit_tile, heading} = result
      on_exit(fn -> cleanup_char(char_id) end)

      # Walk onto exit tile to trigger transfer
      Process.sleep(300)
      send_walk(socket, heading)
      transfer_packets = recv_until_packet(socket, 30, 8000)
      {30, new_map} = find_packet(transfer_packets, 30)
      assert new_map.map_id == exit_tile.dest_map

      # Disconnect
      :gen_tcp.close(socket)
      Process.sleep(500)

      # Reconnect
      ensure_map_started(exit_tile.dest_map)
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      # Should still be on the destination map
      {30, persisted_map} = find_packet(packets2, 30)
      assert persisted_map.map_id == exit_tile.dest_map

      {31, persisted_pos} = find_packet(packets2, 31)
      assert persisted_pos.x == exit_tile.dest_x
      assert persisted_pos.y == exit_tile.dest_y
    end
  end

  describe "concurrent disconnect safety" do
    test "two characters disconnect rapidly without errors", %{port: port} do
      name_a = unique_name()
      name_b = unique_name()

      {socket_a, _packets_a, char_id_a} = login_new(port, name_a)
      {socket_b, _packets_b, char_id_b} = login_new(port, name_b)
      on_exit(fn -> cleanup_char(char_id_a); cleanup_char(char_id_b) end)

      assert char_id_a != nil
      assert char_id_b != nil

      # Both are on map
      assert {:ok, _} = Arena.Map.MapServer.snapshot_entity(1, char_id_a)
      assert {:ok, _} = Arena.Map.MapServer.snapshot_entity(1, char_id_b)

      # Disconnect both rapidly (no sleep between)
      :gen_tcp.close(socket_a)
      :gen_tcp.close(socket_b)

      # Wait for cleanup to complete
      Process.sleep(500)

      # Both sessions should be unregistered
      assert {:error, :not_found} = AoSession.lookup(char_id_a)
      assert {:error, :not_found} = AoSession.lookup(char_id_b)

      # Both should be removed from map
      assert {:error, :not_on_map} = Arena.Map.MapServer.snapshot_entity(1, char_id_a)
      assert {:error, :not_on_map} = Arena.Map.MapServer.snapshot_entity(1, char_id_b)

      # Both should be persisted in DB (not lost)
      assert GameBackend.Characters.get(char_id_a) != nil
      assert GameBackend.Characters.get(char_id_b) != nil
    end
  end

  describe "double login rejection" do
    test "second login with same char_id via Packet 73 returns error", %{port: port} do
      name = unique_name()
      {socket1, _packets1, char_id} = login_new(port, name)
      on_exit(fn -> :gen_tcp.close(socket1); cleanup_char(char_id) end)

      assert char_id != nil

      # Get the session token
      token = GameBackend.Characters.get(char_id).session_token

      # Attempt second login with same char_id on a different connection
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      # Should get error_msg (packet 73)
      assert {73, error} = find_packet(packets2, 73)
      assert error.message =~ "Already connected"
    end

    test "second login with same name via Packet 74 returns error", %{port: port} do
      name = unique_name()
      {socket1, _packets1, char_id} = login_new(port, name)
      on_exit(fn -> :gen_tcp.close(socket1); cleanup_char(char_id) end)

      # Second connection with same name
      socket2 = connect(port)
      send_login_with_name(socket2, name)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      assert {73, error} = find_packet(packets2, 73)
      assert error.message =~ "already taken"
    end
  end
end
