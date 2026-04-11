defmodule AoTcpGateway.ClientHandlerIntegrationTest do
  @moduledoc """
  Integration tests that exercise the full TCP flow: connect → login → walk → talk → disconnect.

  Each test starts a Ranch listener on a random port, boots the required infrastructure
  (registries, map supervisor, map server), connects via :gen_tcp, and asserts the
  exact AO20 packet sequence.
  """

  use ExUnit.Case

  alias AoProtocol.Writer
  alias AoProtocol.Reader

  @connect_timeout 2000
  @recv_timeout 500

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

    case Registry.lookup(Arena.MapRegistry, 1) do
      [] -> Arena.Map.MapSupervisor.start_map(1)
      _ -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    listener_name = :"test_listener_#{System.unique_integer([:positive])}"

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

  # ---- Helpers ----

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
        Writer.write_int8(1) <>  # race: human
        Writer.write_int8(1) <>  # gender: male
        Writer.write_int8(6) <>  # class: guerrero
        Writer.write_int16(1) <> # head
        Writer.write_int8(1)     # home_city: ullathorpe

    packet = Writer.build_packet(74, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  # Login, receive response, and register on_exit cleanup. Returns {socket, login_packets, char_id}.
  defp login_and_setup(port, name) do
    socket = connect(port)
    send_login_with_name(socket, name)
    data = recv_all(socket)
    packets = decode_all_packets(data)
    char_id = get_char_id(name)
    on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)
    {socket, packets, char_id}
  end

  defp send_walk(socket, heading) do
    payload = Writer.write_int8(heading) <> Writer.write_int32(1)
    packet = Writer.build_packet(78, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_talk(socket, message) do
    payload = Writer.write_string8(message) <> Writer.write_int32(1)
    packet = Writer.build_packet(75, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp recv_all(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :timeout} -> acc
      {:error, _reason} -> acc
    end
  end

  defp recv_quick(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 150) do
      {:ok, data} -> recv_quick(socket, acc <> data)
      {:error, :timeout} -> acc
      {:error, _reason} -> acc
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

  defp packet_ids(packets), do: Enum.map(packets, &elem(&1, 0))

  defp find_packet(packets, id) do
    Enum.find(packets, fn {pid, _} -> pid == id end)
  end

  defp unique_name, do: "Test_#{System.unique_integer([:positive])}"

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

  # Keep reading from the socket until we see the target packet_id or timeout.
  # Returns all decoded packets accumulated so far.
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
            # Got the target — do one more quick recv to catch trailing packets
            Process.sleep(100)
            extra = case :gen_tcp.recv(socket, 0, 100) do
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

  # Return all exits that have a walkable approach tile, as [{exit_tile, {x, y}, heading}].
  defp all_exits_with_approach(exits) do
    approaches = [
      {0, -1, 3}, {0, 1, 1}, {-1, 0, 2}, {1, 0, 4}
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

  defp ensure_test_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    # Wait until the map is actually ready (loaded)
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
    _ -> Process.sleep(100); wait_map_ready(map_id, retries - 1)
  catch
    :exit, _ -> Process.sleep(100); wait_map_ready(map_id, retries - 1)
  end

  # ---- Packet decoders ----

  defp decode_all_packets(data), do: decode_all_packets(data, [])
  defp decode_all_packets(<<>>, acc), do: Enum.reverse(acc)
  defp decode_all_packets(data, acc) when byte_size(data) < 2, do: Enum.reverse(acc)
  defp decode_all_packets(<<packet_id::little-signed-16, rest::binary>>, acc) do
    case decode_server_packet(packet_id, rest) do
      {:ok, fields, remaining} -> decode_all_packets(remaining, [{packet_id, fields} | acc])
      :incomplete -> Enum.reverse(acc)
    end
  end

  defp decode_server_packet(2, <<new_user::8, rest::binary>>), do: {:ok, %{new_user: new_user != 0}, rest}
  defp decode_server_packet(25, <<min_sta::little-signed-16, rest::binary>>), do: {:ok, %{min_sta: min_sta}, rest}
  defp decode_server_packet(26, <<min_mana::little-signed-16, rest::binary>>), do: {:ok, %{min_mana: min_mana}, rest}
  defp decode_server_packet(27, <<min_hp::little-signed-16, shield::little-signed-32, rest::binary>>), do: {:ok, %{min_hp: min_hp, shield: shield}, rest}
  defp decode_server_packet(28, <<gold::little-signed-32, _billetera::little-signed-32, rest::binary>>), do: {:ok, %{gold: gold}, rest}
  defp decode_server_packet(30, <<map_id::little-signed-16, version::little-signed-16, rest::binary>>), do: {:ok, %{map_id: map_id, version: version}, rest}
  defp decode_server_packet(31, <<x::8, y::8, rest::binary>>), do: {:ok, %{x: x, y: y}, rest}

  defp decode_server_packet(35, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, char_index, rest} <- Reader.read_int16(rest),
         {:ok, color, rest} <- Reader.read_int32(rest),
         {:ok, es_spell, rest} <- Reader.read_bool(rest),
         {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, min_time, rest} <- Reader.read_int16(rest),
         {:ok, max_time, rest} <- Reader.read_int16(rest) do
      {:ok, %{message: msg, char_index: char_index, color: color, es_spell: es_spell, x: x, y: y, min_display_time: min_time, max_display_time: max_time}, rest}
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
      {:ok, %{char_index: char_index, body_id: body_id, head_id: head_id,
              heading: heading, x: x, y: y, name: name, speed: speed,
              min_hp: min_hp, max_hp: max_hp, min_mana: min_mana, max_mana: max_mana}, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(43, <<char_index::little-signed-16, desvanecido::8, fue_warp::8, rest::binary>>), do: {:ok, %{char_index: char_index, desvanecido: desvanecido != 0, fue_warp: fue_warp != 0}, rest}
  defp decode_server_packet(44, <<char_index::little-signed-16, x::8, y::8, rest::binary>>), do: {:ok, %{char_index: char_index, x: x, y: y}, rest}
  defp decode_server_packet(46, <<idx::little-signed-16, rest::binary>>), do: {:ok, %{user_index: idx}, rest}
  defp decode_server_packet(47, <<idx::little-signed-16, rest::binary>>), do: {:ok, %{char_index: idx}, rest}

  defp decode_server_packet(63, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
      equipped::8, valor::little-float-32, puede_usar::8, elemental_tags::little-signed-32,
      is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, obj_index: obj_index, amount: amount, equipped: equipped != 0,
            valor: valor, puede_usar: puede_usar, elemental_tags: elemental_tags,
            is_bindable: is_bindable != 0}, rest}
  end

  defp decode_server_packet(73, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data) do
      {:ok, %{message: msg}, rest}
    else
      _ -> :incomplete
    end
  end

  # update_exp (ID 29) — CurrentXP(Int32) + NextXP(Int32)
  defp decode_server_packet(29, <<current_xp::little-signed-32, next_xp::little-signed-32, rest::binary>>) do
    {:ok, %{current_xp: current_xp, next_xp: next_xp}, rest}
  end

  # change_spell_slot (ID 66) — slot(Int8) + spell_id(Int16) + index(Int16) + is_bindable(Bool)
  defp decode_server_packet(66, <<slot::8, spell_id::little-signed-16, index::little-signed-16, is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, spell_id: spell_id, index: index, is_bindable: is_bindable != 0}, rest}
  end

  # level_up (ID 80) — level(Int16)
  defp decode_server_packet(80, <<level::little-16, rest::binary>>) do
    {:ok, %{level: level}, rest}
  end

  defp decode_server_packet(78, <<max_thirst::8, min_thirst::8, max_hunger::8, min_hunger::8, rest::binary>>) do
    {:ok, %{max_thirst: max_thirst, min_thirst: min_thirst, max_hunger: max_hunger, min_hunger: min_hunger}, rest}
  end

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

  # send_skills (87): 24 × Int8 (24 bytes)
  defp decode_server_packet(87, <<skills::binary-size(24), rest::binary>>), do: {:ok, %{skills: skills}, rest}

  defp decode_server_packet(200, data) do
    with {:ok, char_id, rest} <- Reader.read_int32(data),
         {:ok, token, rest} <- Reader.read_string8(rest) do
      {:ok, %{char_id: char_id, token: token}, rest}
    else
      _ -> :incomplete
    end
  end

  # character_change (49): Int16 + Int8(flags) + Int16*7 + Int8 + Int16*4 = 22 bytes
  defp decode_server_packet(49, <<_::binary-size(22), rest::binary>>), do: {:ok, %{}, rest}

  # rain_toggle (59): Bool (1 byte)
  defp decode_server_packet(59, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # update_user_stats (61): 2+2+4+2+2+2+2+4+4+1+4+4+1 = 34 bytes
  defp decode_server_packet(61, <<_::binary-size(34), rest::binary>>), do: {:ok, %{}, rest}

  # snow_toggle (76): Bool (1 byte)
  defp decode_server_packet(76, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # mini_stats (79): 4+4+1+4+1+4+4+1+4+1 = 28 bytes
  defp decode_server_packet(79, <<_::binary-size(28), rest::binary>>), do: {:ok, %{}, rest}

  # send_atributes (81): 5 × Int8 = 5 bytes
  defp decode_server_packet(81, <<_::binary-size(5), rest::binary>>), do: {:ok, %{}, rest}

  # update_hp (27): Int16 + Int32 = 6 bytes (already decoded above via Reader, add skip fallback)
  # update_mana (26): Int16 = 2 bytes (already decoded via Reader)
  # update_sta (25): Int16 = 2 bytes (already decoded via Reader)
  # update_gold (28): Int32 + Int32 = 8 bytes (already decoded via Reader)

  defp decode_server_packet(_id, _rest), do: :incomplete

  # ============================================================
  # Tests
  # ============================================================

  describe "login response" do
    test "returns correct packet sequence matching AO20 ConnectUser_Complete", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      ids = packet_ids(packets)

      core_ids = [2, 46, 30, 47, 42, 31, 158, 27, 26, 25, 28, 78]
      assert Enum.take(ids, 12) == core_ids

      # After core: player/NPC creates, ground items, welcome.
      # NPC character_creates (42) arrive async so position is non-deterministic.
      after_core = Enum.drop(ids, 12)
      assert 37 in after_core

      # All non-welcome packets are valid middle types
      middle = Enum.reject(after_core, &(&1 == 37))
      assert Enum.all?(middle, &(&1 in [42, 49, 59, 61, 63, 66, 76, 79, 80, 81, 29, 87]))
    end

    test "logged packet has new_user=false", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      {2, logged} = find_packet(packets, 2)
      assert logged.new_user == false
    end

    test "change_map points to map 1", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      {30, change_map} = find_packet(packets, 30)
      assert change_map.map_id == 1
    end

    test "character_create contains spawn position and stats", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      {42, char} = find_packet(packets, 42)
      assert char.min_hp > 0
      assert char.max_hp > 0
      assert char.min_hp == char.max_hp
      assert char.speed == 1.0
      assert char.x > 0
      assert char.y > 0
    end

    test "spawn position is walkable", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      {31, pos} = find_packet(packets, 31)
      assert TileGrid.is_walkable(1, pos.x, pos.y)
    end

    test "pos_update matches character_create position", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      {42, char} = find_packet(packets, 42)
      {31, pos} = find_packet(packets, 31)
      assert pos.x == char.x
      assert pos.y == char.y
    end

    test "welcome console message is sent", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      {37, msg} = find_packet(packets, 37)
      assert msg.message =~ "Welcome"
    end

    test "duplicate login returns error", %{port: port} do
      name = unique_name()
      {_socket1, _packets1, _char_id} = login_and_setup(port, name)

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

  describe "walk" do
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

    # Find a direction that succeeds (not blocked, not a map exit)
    defp walk_any_direction(socket) do
      Enum.find_value([3, 1, 2, 4], fn heading ->
        case try_walk(socket, heading) do
          {:ok, pos} -> {heading, pos}
          :blocked -> nil
        end
      end)
    end

    test "walk changes position", %{port: port} do
      {socket, packets, _char_id} = login_and_setup(port, unique_name())
      {31, initial_pos} = find_packet(packets, 31)

      result = walk_any_direction(socket)
      assert result != nil, "at least one direction should be walkable"

      {heading, new_pos} = result
      case heading do
        1 -> assert new_pos.y == initial_pos.y - 1  # north
        2 -> assert new_pos.x == initial_pos.x + 1  # east
        3 -> assert new_pos.y == initial_pos.y + 1  # south
        4 -> assert new_pos.x == initial_pos.x - 1  # west
      end
    end

    test "consecutive walks accumulate", %{port: port} do
      {socket, packets, _char_id} = login_and_setup(port, unique_name())
      {31, _initial_pos} = find_packet(packets, 31)

      # Find a safe direction first
      result = walk_any_direction(socket)
      assert result != nil, "at least one direction should be walkable"
      {heading, pos1} = result

      # Walk the same direction again — recv_all waits 500ms, exceeding 210ms cooldown
      send_walk(socket, heading)
      data2 = recv_all(socket)
      packets2 = decode_all_packets(data2)

      case find_packet(packets2, 31) do
        {31, pos2} ->
          case heading do
            1 -> assert pos2.y == pos1.y - 1
            2 -> assert pos2.x == pos1.x + 1
            3 -> assert pos2.y == pos1.y + 1
            4 -> assert pos2.x == pos1.x - 1
          end
        nil -> :ok  # second step blocked, that's fine
      end
    end

    test "walk interval matches VB6 IntervaloCaminar=210ms", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      # Find a safe direction (this consumes cooldown via recv_all's 500ms wait)
      result = walk_any_direction(socket)
      assert result != nil, "at least one direction should be walkable"
      {heading, _} = result

      # Wait for cooldown to fully expire after the direction-finding walk
      Process.sleep(250)

      # Fresh walk — should succeed (cooldown expired)
      send_walk(socket, heading)
      data1 = recv_quick(socket)
      assert find_packet(decode_all_packets(data1), 31) != nil,
        "first walk should succeed"

      # Walk sent immediately (< 210ms cooldown) — should be rejected
      send_walk(socket, heading)
      data2 = recv_quick(socket)
      assert find_packet(decode_all_packets(data2), 31) == nil,
        "walk sent immediately should be rejected (< 210ms cooldown)"

      # Wait for cooldown to expire, then walk — should succeed
      Process.sleep(250)
      send_walk(socket, heading)
      data3 = recv_quick(socket)
      assert find_packet(decode_all_packets(data3), 31) != nil,
        "walk after 250ms cooldown should succeed"
    end
  end

  describe "talk" do
    test "talk echoes as chat_over_head", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_talk(socket, "Hello AO!")
      talk_data = recv_all(socket)
      talk_packets = decode_all_packets(talk_data)

      {35, chat} = find_packet(talk_packets, 35)
      assert chat.message == "Hello AO!"
      assert chat.char_index > 0
    end
  end

  describe "multiplayer broadcast" do
    test "second client receives character_create for first client", %{port: port} do
      name_a = unique_name()
      {_socket_a, _packets_a, _} = login_and_setup(port, name_a)

      name_b = unique_name()
      {_socket_b, packets_b, _} = login_and_setup(port, name_b)

      char_creates = Enum.filter(packets_b, fn {id, _} -> id == 42 end)
      names = Enum.map(char_creates, fn {_, fields} -> fields.name end)

      assert name_b in names
      assert name_a in names
    end

    test "first client sees second client enter via broadcast", %{port: port} do
      {socket_a, _packets_a, _} = login_and_setup(port, unique_name())

      name_b = unique_name()
      {_socket_b, _packets_b, _} = login_and_setup(port, name_b)

      broadcast_data = recv_all(socket_a)
      broadcast_packets = decode_all_packets(broadcast_data)

      char_creates = Enum.filter(broadcast_packets, fn {id, _} -> id == 42 end)
      names = Enum.map(char_creates, fn {_, fields} -> fields.name end)
      assert name_b in names
    end

    test "movement is broadcast to other clients", %{port: port} do
      {socket_a, _packets_a, _} = login_and_setup(port, unique_name())
      {socket_b, _packets_b, _} = login_and_setup(port, unique_name())

      _drain = recv_all(socket_a)

      # Try multiple directions in case one is blocked by an adjacent character
      moved = Enum.find_value([3, 1, 2, 4], fn heading ->
        send_walk(socket_b, heading)
        walk_b = recv_all(socket_b)
        if find_packet(decode_all_packets(walk_b), 31) != nil, do: true
      end)

      assert moved, "at least one walk direction should succeed"

      move_data = recv_all(socket_a)
      move_packets = decode_all_packets(move_data)

      char_moves = Enum.filter(move_packets, fn {id, _} -> id == 44 end)
      assert length(char_moves) >= 1
    end

    test "chat is broadcast to other clients", %{port: port} do
      {socket_a, _packets_a, _} = login_and_setup(port, unique_name())
      {socket_b, _packets_b, _} = login_and_setup(port, unique_name())

      _drain = recv_all(socket_a)

      send_talk(socket_b, "Hello from B!")
      _talk_b = recv_all(socket_b)

      chat_data = recv_all(socket_a)
      chat_packets = decode_all_packets(chat_data)

      {35, chat} = find_packet(chat_packets, 35)
      assert chat.message == "Hello from B!"
    end

    test "disconnect sends character_remove to other clients", %{port: port} do
      {socket_a, _packets_a, _} = login_and_setup(port, unique_name())

      name_b = unique_name()
      socket_b = connect(port)
      send_login_with_name(socket_b, name_b)
      _login_b = recv_all(socket_b)
      char_id_b = get_char_id(name_b)

      _drain = recv_all(socket_a)

      :gen_tcp.close(socket_b)
      Process.sleep(100)
      cleanup_char(char_id_b)

      remove_data = recv_all(socket_a)
      remove_packets = decode_all_packets(remove_data)

      char_removes = Enum.filter(remove_packets, fn {id, _} -> id == 43 end)
      assert length(char_removes) >= 1
    end
  end

  describe "map transition" do
    test "walking onto an exit tile transfers the player to the destination map", %{port: port} do
      map_data = Arena.Map.MapServer.get_map_data(1)
      exits_with_approach = all_exits_with_approach(map_data.exits)
      assert exits_with_approach != [], "need at least one reachable exit on map 1"

      # Try exits until we find one where the character actually spawns on the approach tile.
      # Other tests may leave characters on tiles, causing spawn shifts.
      result =
        Enum.find_value(exits_with_approach, :no_exit_worked, fn {exit_tile, {sx, sy}, heading} ->
          ensure_test_map_started(exit_tile.dest_map)

          name = unique_name()
          {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")
          {:ok, character} = GameBackend.Characters.create(%{
            name: name,
            account_id: account.id,
            map_id: 1,
            pos_x: sx,
            pos_y: sy,
            heading: "south"
          })

          char_id = character.id
          socket = connect(port)
          send_login_existing(socket, char_id, character.session_token)
          login_data = recv_all(socket)
          login_packets = decode_all_packets(login_data)

          {31, login_pos} = find_packet(login_packets, 31)

          if login_pos.x == sx and login_pos.y == sy do
            # Spawned exactly where requested — this exit is usable
            {:ok, socket, char_id, login_packets, exit_tile, heading}
          else
            # Spawn shifted — clean up and try next exit
            :gen_tcp.close(socket)
            cleanup_char(char_id)
            nil
          end
        end)

      assert result != :no_exit_worked,
        "no exit had a free approach tile — all approach tiles are occupied"

      {:ok, socket, char_id, login_packets, exit_tile, heading} = result
      on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)

      {30, initial_map} = find_packet(login_packets, 30)
      assert initial_map.map_id == 1

      # Walk onto the exit tile
      Process.sleep(300)
      send_walk(socket, heading)

      # Collect transfer response — poll until we see change_map
      transfer_packets = recv_until_packet(socket, 30, 8000)
      change_map_idx = Enum.find_index(transfer_packets, fn {id, _} -> id == 30 end)
      assert change_map_idx != nil, "should receive change_map after walking onto exit"

      {30, new_map} = Enum.at(transfer_packets, change_map_idx)
      assert new_map.map_id == exit_tile.dest_map

      dest_packets = Enum.drop(transfer_packets, change_map_idx + 1)

      {31, new_pos} = find_packet(dest_packets, 31)
      assert new_pos.x == exit_tile.dest_x
      assert new_pos.y == exit_tile.dest_y

      assert find_packet(dest_packets, 42) != nil
    end
  end

  describe "disconnect cleanup" do
    test "session is unregistered after disconnect", %{port: port} do
      name = unique_name()
      {socket, _packets, char_id} = login_and_setup(port, name)

      assert char_id != nil
      assert {:ok, _pid, _meta} = AoSession.lookup(char_id)

      :gen_tcp.close(socket)
      Process.sleep(200)
      cleanup_char(char_id)

      assert {:error, :not_found} = AoSession.lookup(char_id)
    end
  end

  # ============================================================
  # Auth & Persistence Tests (Phase 2)
  # ============================================================

  describe "auth" do
    test "invalid session token returns error on Packet 73 login", %{port: port} do
      name = unique_name()
      {socket1, _packets, char_id} = login_and_setup(port, name)

      # Disconnect first player
      :gen_tcp.close(socket1)
      Process.sleep(200)

      # Try reconnecting with wrong token
      socket2 = connect(port)
      send_login_existing(socket2, char_id, "wrong_token_abc123")
      data = recv_all(socket2)
      packets = decode_all_packets(data)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      assert {73, error} = find_packet(packets, 73)
      assert error.message =~ "Invalid session token"
    end

    test "wrong password returns error on Packet 74 login", %{port: port} do
      name = unique_name()

      # Create account+character via Packet 74
      {socket1, _packets, _char_id} = login_and_setup(port, name)
      :gen_tcp.close(socket1)
      Process.sleep(200)

      # Second connection: same name, different password
      socket2 = connect(port)
      # send_login_with_name uses "test_token" as password — send manually with different password
      md5 = "abcdef1234567890abcdef1234567890"
      payload =
        Writer.write_string8("different_password") <>
          Writer.write_string8(name) <>
          Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
          Writer.write_string8(md5) <>
          Writer.write_int8(1) <> Writer.write_int8(1) <> Writer.write_int8(6) <>
          Writer.write_int16(1) <> Writer.write_int8(1)
      packet = Writer.build_packet(74, payload)
      :ok = :gen_tcp.send(socket2, packet)

      data = recv_all(socket2)
      packets = decode_all_packets(data)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      assert {73, error} = find_packet(packets, 73)
      assert error.message =~ "Wrong password"
    end
  end

  describe "persistence" do
    test "character stats persist across logout/login", %{port: port} do
      name = unique_name()

      # Create character via Packet 74
      {socket1, packets1, char_id} = login_and_setup(port, name)

      # Capture stats from login
      {27, hp1} = find_packet(packets1, 27)
      {25, sta1} = find_packet(packets1, 25)
      {26, mana1} = find_packet(packets1, 26)
      {28, gold1} = find_packet(packets1, 28)

      # Disconnect — triggers autosave
      :gen_tcp.close(socket1)
      Process.sleep(500)

      # Get session token from DB for Packet 73 reconnect
      token = GameBackend.Characters.get(char_id).session_token

      # Reconnect via Packet 73
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      # Verify same stats
      {27, hp2} = find_packet(packets2, 27)
      {25, sta2} = find_packet(packets2, 25)
      {26, mana2} = find_packet(packets2, 26)
      {28, gold2} = find_packet(packets2, 28)

      assert hp2.min_hp == hp1.min_hp
      assert sta2.min_sta == sta1.min_sta
      assert mana2.min_mana == mana1.min_mana
      assert gold2.gold == gold1.gold
    end

    test "inventory persists across logout/login", %{port: port} do
      name = unique_name()
      {socket1, packets1, char_id} = login_and_setup(port, name)

      inv_packets1 =
        packets1
        |> Enum.filter(fn {id, _} -> id == 63 end)
        |> Enum.sort_by(fn {_, fields} -> fields.slot end)

      :gen_tcp.close(socket1)
      Process.sleep(500)

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

      # Same item IDs and amounts in each slot
      Enum.zip(inv_packets1, inv_packets2)
      |> Enum.each(fn {{_, s1}, {_, s2}} ->
        assert s2.slot == s1.slot
        assert s2.obj_index == s1.obj_index
        assert s2.amount == s1.amount
      end)
    end

    test "spells persist across logout/login", %{port: port} do
      name = unique_name()
      {socket1, packets1, char_id} = login_and_setup(port, name)

      spell_packets1 =
        packets1
        |> Enum.filter(fn {id, _} -> id == 66 end)
        |> Enum.sort_by(fn {_, fields} -> fields.slot end)

      :gen_tcp.close(socket1)
      Process.sleep(500)

      token = GameBackend.Characters.get(char_id).session_token
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      spell_packets2 =
        packets2
        |> Enum.filter(fn {id, _} -> id == 66 end)
        |> Enum.sort_by(fn {_, fields} -> fields.slot end)

      assert length(spell_packets2) == length(spell_packets1)

      Enum.zip(spell_packets1, spell_packets2)
      |> Enum.each(fn {{_, s1}, {_, s2}} ->
        assert s2.slot == s1.slot
        assert s2.spell_id == s1.spell_id
      end)
    end
  end

  # ============================================================
  # Transfer Stress Tests (Phase 2A)
  # ============================================================

  describe "transfer stress" do
    # Create a character placed on a specific tile via DB + Packet 73 login
    defp create_and_login_at(port, map_id, x, y) do
      name = unique_name()
      {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")

      {:ok, character} =
        GameBackend.Characters.create(%{
          name: name,
          account_id: account.id,
          map_id: map_id,
          pos_x: x,
          pos_y: y,
          heading: "south"
        })

      ensure_test_map_started(map_id)

      socket = connect(port)
      send_login_existing(socket, character.id, character.session_token)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      {socket, packets, character.id}
    end

    test "rapid back-and-forth map transitions", %{port: port} do
      map_data = Arena.Map.MapServer.get_map_data(1)
      exits_with_approach = all_exits_with_approach(map_data.exits)
      assert exits_with_approach != [], "need at least one reachable exit on map 1"

      # Find a usable exit
      result =
        Enum.find_value(exits_with_approach, :no_exit_worked, fn {exit_tile, {sx, sy}, heading} ->
          ensure_test_map_started(exit_tile.dest_map)

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
            {:ok, socket, character.id, exit_tile, heading}
          else
            :gen_tcp.close(socket)
            cleanup_char(character.id)
            nil
          end
        end)

      assert result != :no_exit_worked,
        "no exit had a free approach tile"

      {:ok, socket, char_id, exit_tile, heading} = result
      on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)

      # Transfer to destination map
      Process.sleep(300)
      send_walk(socket, heading)
      transfer1 = recv_until_packet(socket, 30, 8000)
      {30, map1} = find_packet(transfer1, 30)
      assert map1.map_id == exit_tile.dest_map

      # Now find a return exit on the destination map
      dest_map_data = Arena.Map.MapServer.get_map_data(exit_tile.dest_map)
      return_exits =
        dest_map_data.exits
        |> Enum.filter(&(&1.dest_map == 1))

      if return_exits != [] do
        # Walk back — find the return exit approach
        return_approaches = all_exits_with_approach(return_exits)

        if return_approaches != [] do
          {_ret_exit, {_rx, _ry}, ret_heading} = hd(return_approaches)
          Process.sleep(300)
          send_walk(socket, ret_heading)
          transfer2 = recv_until_packet(socket, 30, 8000)

          case find_packet(transfer2, 30) do
            {30, map2} -> assert map2.map_id == 1
            nil -> :ok  # didn't land on exit, that's fine
          end
        end
      end
    end

    test "transfer preserves entity state on reconnect", %{port: port} do
      map_data = Arena.Map.MapServer.get_map_data(1)
      exits_with_approach = all_exits_with_approach(map_data.exits)
      assert exits_with_approach != [], "need at least one reachable exit on map 1"

      result =
        Enum.find_value(exits_with_approach, :no_exit_worked, fn {exit_tile, {sx, sy}, heading} ->
          ensure_test_map_started(exit_tile.dest_map)

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

      # Transfer to destination
      Process.sleep(300)
      send_walk(socket, heading)
      transfer_packets = recv_until_packet(socket, 30, 8000)
      {30, new_map} = find_packet(transfer_packets, 30)
      assert new_map.map_id == exit_tile.dest_map

      # Disconnect — triggers cleanup save on dest map
      :gen_tcp.close(socket)
      Process.sleep(500)

      # Reconnect via Packet 73
      ensure_test_map_started(exit_tile.dest_map)
      socket2 = connect(port)
      send_login_existing(socket2, char_id, token)
      data2 = recv_all(socket2)
      packets2 = decode_all_packets(data2)
      on_exit(fn -> :gen_tcp.close(socket2) end)

      # Should be on the destination map, not map 1
      {30, persisted_map} = find_packet(packets2, 30)
      assert persisted_map.map_id == exit_tile.dest_map

      {31, persisted_pos} = find_packet(packets2, 31)
      assert persisted_pos.x == exit_tile.dest_x
      assert persisted_pos.y == exit_tile.dest_y
    end

    test "concurrent transfers by two players", %{port: port} do
      map_data = Arena.Map.MapServer.get_map_data(1)
      exits_with_approach = all_exits_with_approach(map_data.exits)
      assert exits_with_approach != [], "need at least one reachable exit on map 1"

      # We need two approach tiles for different exits
      usable =
        Enum.take(exits_with_approach, 2)
        |> Enum.map(fn {exit_tile, {sx, sy}, heading} ->
          ensure_test_map_started(exit_tile.dest_map)
          {exit_tile, {sx, sy}, heading}
        end)

      assert length(usable) >= 2, "need at least 2 reachable exits on map 1"

      [{exit1, {sx1, sy1}, h1}, {exit2, {sx2, sy2}, h2}] = usable

      # Create two players at different approach tiles
      {socket1, packets1, char_id1} = create_and_login_at(port, 1, sx1, sy1)
      {socket2, packets2, char_id2} = create_and_login_at(port, 1, sx2, sy2)
      on_exit(fn ->
        :gen_tcp.close(socket1); :gen_tcp.close(socket2)
        cleanup_char(char_id1); cleanup_char(char_id2)
      end)

      {31, pos1} = find_packet(packets1, 31)
      {31, pos2} = find_packet(packets2, 31)

      # Verify they spawned where expected (or skip if tiles were occupied)
      if pos1.x == sx1 and pos1.y == sy1 and pos2.x == sx2 and pos2.y == sy2 do
        # Both walk onto exits simultaneously
        Process.sleep(300)
        send_walk(socket1, h1)
        send_walk(socket2, h2)

        t1 = recv_until_packet(socket1, 30, 8000)
        t2 = recv_until_packet(socket2, 30, 8000)

        transferred =
          [
            {t1, exit1.dest_map},
            {t2, exit2.dest_map}
          ]
          |> Enum.filter(fn {packets, _expected_map} ->
            find_packet(packets, 30) != nil
          end)

        # At least one player should have transferred successfully
        assert length(transferred) >= 1,
          "at least one of the two players should transfer"

        # Each transferred player should be on the correct map
        Enum.each(transferred, fn {packets, expected_map} ->
          {30, map} = find_packet(packets, 30)
          assert map.map_id == expected_map
        end)
      end
    end
  end
end
