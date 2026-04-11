defmodule AoTcpGateway.TestPacketDecoder do
  @moduledoc """
  Shared packet decoder and TCP helpers for integration/smoke/trace tests.

  Provides a comprehensive `decode_all_packets/1` that handles every known
  server packet type, plus `recv_until_packet/3` and `recv_until_all_packets/3`
  for targeted TCP reads.
  """

  alias AoProtocol.Reader

  # ============================================================
  # TCP recv helpers
  # ============================================================

  @doc "Read until timeout, accumulating all data."
  def recv_all(socket, timeout \\ 500, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> recv_all(socket, timeout, acc <> data)
      {:error, :timeout} -> acc
      {:error, _} -> acc
    end
  end

  @doc "Quick drain with short timeout."
  def recv_quick(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 150) do
      {:ok, data} -> recv_quick(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  @doc """
  Keep reading from socket until the target packet_id is found or timeout.
  Returns decoded `[{id, fields}, ...]` list.
  """
  def recv_until_packet(socket, target_id, timeout_ms) do
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

        {:error, _} ->
          decode_all_packets(acc_data)
      end
    end
  end

  @doc """
  Keep reading from socket until ALL target packet IDs are found or timeout.
  Returns decoded `[{id, fields}, ...]` list.
  """
  def recv_until_all_packets(socket, target_ids, timeout_ms) when is_list(target_ids) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    target_set = MapSet.new(target_ids)
    recv_until_all_loop(socket, target_set, deadline, <<>>)
  end

  defp recv_until_all_loop(socket, target_set, deadline, acc_data) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      decode_all_packets(acc_data)
    else
      case :gen_tcp.recv(socket, 0, min(remaining, 200)) do
        {:ok, data} ->
          all_data = acc_data <> data
          packets = decode_all_packets(all_data)
          found = MapSet.new(Enum.map(packets, &elem(&1, 0)))

          if MapSet.subset?(target_set, found) do
            Process.sleep(100)

            extra =
              case :gen_tcp.recv(socket, 0, 100) do
                {:ok, d} -> d
                {:error, _} -> <<>>
              end

            decode_all_packets(all_data <> extra)
          else
            recv_until_all_loop(socket, target_set, deadline, all_data)
          end

        {:error, :timeout} ->
          recv_until_all_loop(socket, target_set, deadline, acc_data)

        {:error, _} ->
          decode_all_packets(acc_data)
      end
    end
  end

  # ============================================================
  # Convenience
  # ============================================================

  def packet_ids(packets), do: Enum.map(packets, &elem(&1, 0))

  def find_packet(packets, id) do
    Enum.find(packets, fn {pid, _} -> pid == id end)
  end

  def has_packet?(packets, id) do
    Enum.any?(packets, fn {pid, _} -> pid == id end)
  end

  # ============================================================
  # Packet decoders — comprehensive, handles all known server packets
  # ============================================================

  def decode_all_packets(data), do: decode_all_packets(data, [])
  defp decode_all_packets(<<>>, acc), do: Enum.reverse(acc)
  defp decode_all_packets(data, acc) when byte_size(data) < 2, do: Enum.reverse(acc)

  defp decode_all_packets(<<packet_id::little-signed-16, rest::binary>>, acc) do
    case decode_server_packet(packet_id, rest) do
      {:ok, fields, remaining} -> decode_all_packets(remaining, [{packet_id, fields} | acc])
      :incomplete -> Enum.reverse(acc)
    end
  end

  # -- Empty packets --
  defp decode_server_packet(id, rest) when id in [1, 7, 8, 9, 10, 11, 13, 16, 17, 18, 19, 20, 21, 22, 23, 58, 96],
    do: {:ok, %{}, rest}

  # logged (2): Bool new_user
  defp decode_server_packet(2, <<new_user::8, rest::binary>>),
    do: {:ok, %{new_user: new_user != 0}, rest}

  # navigate_toggle (5): Bool
  defp decode_server_packet(5, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # user_commerce_init (12): string8
  defp decode_server_packet(12, data), do: decode_single_string(data)

  # update_sta (25): Int16
  defp decode_server_packet(25, <<min_sta::little-signed-16, rest::binary>>),
    do: {:ok, %{min_sta: min_sta}, rest}

  # update_mana (26): Int16
  defp decode_server_packet(26, <<min_mana::little-signed-16, rest::binary>>),
    do: {:ok, %{min_mana: min_mana}, rest}

  # update_hp (27): Int16 + Int32
  defp decode_server_packet(27, <<min_hp::little-signed-16, shield::little-signed-32, rest::binary>>),
    do: {:ok, %{min_hp: min_hp, shield: shield}, rest}

  # update_gold (28): Int32 + Int32
  defp decode_server_packet(28, <<gold::little-signed-32, _billetera::little-signed-32, rest::binary>>),
    do: {:ok, %{gold: gold}, rest}

  # update_exp (29): Int32 + Int32
  defp decode_server_packet(29, <<current_xp::little-signed-32, next_xp::little-signed-32, rest::binary>>),
    do: {:ok, %{current_xp: current_xp, next_xp: next_xp}, rest}

  # change_map (30): Int16 + Int16
  defp decode_server_packet(30, <<map_id::little-signed-16, version::little-signed-16, rest::binary>>),
    do: {:ok, %{map_id: map_id, version: version}, rest}

  # pos_update (31): Int8 + Int8
  defp decode_server_packet(31, <<x::8, y::8, rest::binary>>),
    do: {:ok, %{x: x, y: y}, rest}

  # npc_hit_user (32), user_hitted_by_user (33), user_hitted_user (34): 7 bytes each
  defp decode_server_packet(id, <<_::binary-size(7), rest::binary>>) when id in [32, 33, 34],
    do: {:ok, %{}, rest}

  # chat_over_head (35): string8 + Int16 + Int32 + Bool + Int8 + Int8 + Int16 + Int16
  defp decode_server_packet(35, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, char_index, rest} <- Reader.read_int16(rest),
         {:ok, color, rest} <- Reader.read_int32(rest),
         {:ok, es_spell, rest} <- Reader.read_bool(rest),
         {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, min_time, rest} <- Reader.read_int16(rest),
         {:ok, max_time, rest} <- Reader.read_int16(rest) do
      {:ok, %{message: msg, char_index: char_index, color: color, es_spell: es_spell,
              x: x, y: y, min_display_time: min_time, max_display_time: max_time}, rest}
    else
      _ -> :incomplete
    end
  end

  # console_msg (37): string8 + Int8
  defp decode_server_packet(37, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, font, rest} <- Reader.read_int8(rest) do
      {:ok, %{message: msg, font_index: font}, rest}
    else
      _ -> :incomplete
    end
  end

  # console_faction_message (38): string8 + Int8
  defp decode_server_packet(38, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, font, rest} <- Reader.read_int8(rest) do
      {:ok, %{message: msg, font_index: font}, rest}
    else
      _ -> :incomplete
    end
  end

  # guild_chat (39), show_message_box (40): string8
  defp decode_server_packet(id, data) when id in [39, 40], do: decode_single_string(data)

  # character_create (42): complex multi-field
  defp decode_server_packet(42, data) do
    with {:ok, char_index, r} <- Reader.read_int16(data),
         {:ok, body_id, r} <- Reader.read_int16(r),
         {:ok, head_id, r} <- Reader.read_int16(r),
         {:ok, heading, r} <- Reader.read_int8(r),
         {:ok, x, r} <- Reader.read_int8(r),
         {:ok, y, r} <- Reader.read_int8(r),
         {:ok, _weapon, r} <- Reader.read_int16(r),
         {:ok, _shield, r} <- Reader.read_int16(r),
         {:ok, _helmet, r} <- Reader.read_int16(r),
         {:ok, _cart, r} <- Reader.read_int16(r),
         {:ok, _backpack, r} <- Reader.read_int16(r),
         {:ok, _fx, r} <- Reader.read_int16(r),
         {:ok, _fx_loops, r} <- Reader.read_int16(r),
         {:ok, name, r} <- Reader.read_string8(r),
         {:ok, _status, r} <- Reader.read_int8(r),
         {:ok, _privileges, r} <- Reader.read_int8(r),
         {:ok, _particula_fx, r} <- Reader.read_int8(r),
         {:ok, _head_aura, r} <- Reader.read_string8(r),
         {:ok, _arma_aura, r} <- Reader.read_string8(r),
         {:ok, _body_aura, r} <- Reader.read_string8(r),
         {:ok, _dm_aura, r} <- Reader.read_string8(r),
         {:ok, _rm_aura, r} <- Reader.read_string8(r),
         {:ok, _otra_aura, r} <- Reader.read_string8(r),
         {:ok, _escudo_aura, r} <- Reader.read_string8(r),
         {:ok, speed, r} <- Reader.read_real32(r),
         {:ok, _es_npc, r} <- Reader.read_int8(r),
         {:ok, _appear, r} <- Reader.read_int8(r),
         {:ok, _group, r} <- Reader.read_int16(r),
         {:ok, _clan, r} <- Reader.read_int16(r),
         {:ok, _clan_nivel, r} <- Reader.read_int8(r),
         {:ok, min_hp, r} <- Reader.read_int32(r),
         {:ok, max_hp, r} <- Reader.read_int32(r),
         {:ok, min_mana, r} <- Reader.read_int32(r),
         {:ok, max_mana, r} <- Reader.read_int32(r),
         {:ok, _simbolo, r} <- Reader.read_int8(r),
         {:ok, _flags, r} <- Reader.read_int8(r),
         {:ok, _tipo_usuario, r} <- Reader.read_int8(r),
         {:ok, _team_captura, r} <- Reader.read_int8(r),
         {:ok, _tiene_bandera, r} <- Reader.read_int8(r),
         {:ok, _npc_num, r} <- Reader.read_int16(r) do
      {:ok, %{char_index: char_index, body_id: body_id, head_id: head_id,
              heading: heading, x: x, y: y, name: name, speed: speed,
              min_hp: min_hp, max_hp: max_hp, min_mana: min_mana, max_mana: max_mana}, r}
    else
      _ -> :incomplete
    end
  end

  # character_remove (43): Int16 + Int8 + Int8
  defp decode_server_packet(43, <<ci::little-signed-16, d::8, w::8, rest::binary>>),
    do: {:ok, %{char_index: ci, desvanecido: d != 0, fue_warp: w != 0}, rest}

  # character_move (44): Int16 + Int8 + Int8
  defp decode_server_packet(44, <<ci::little-signed-16, x::8, y::8, rest::binary>>),
    do: {:ok, %{char_index: ci, x: x, y: y}, rest}

  # user_index_in_server (46): Int16
  defp decode_server_packet(46, <<idx::little-signed-16, rest::binary>>),
    do: {:ok, %{user_index: idx}, rest}

  # user_char_index (47): Int16
  defp decode_server_packet(47, <<idx::little-signed-16, rest::binary>>),
    do: {:ok, %{char_index: idx}, rest}

  # character_change (49): 22 bytes
  defp decode_server_packet(49, <<_::binary-size(22), rest::binary>>), do: {:ok, %{}, rest}

  # object_create (50): Int8 + Int8 + Int16
  defp decode_server_packet(50, <<x::8, y::8, obj_index::little-signed-16, rest::binary>>),
    do: {:ok, %{x: x, y: y, obj_index: obj_index}, rest}

  # object_delete (52): Int8 + Int8
  defp decode_server_packet(52, <<x::8, y::8, rest::binary>>),
    do: {:ok, %{x: x, y: y}, rest}

  # play_midi (54): Int16 + Int16
  defp decode_server_packet(54, <<midi_id::little-signed-16, loops::little-signed-16, rest::binary>>),
    do: {:ok, %{midi_id: midi_id, loops: loops}, rest}

  # play_wave (55): Int16 + Int8 + Int8
  defp decode_server_packet(55, <<wave_id::little-signed-16, x::8, y::8, rest::binary>>),
    do: {:ok, %{wave_id: wave_id, x: x, y: y}, rest}

  # guild_list (56): string8
  defp decode_server_packet(56, data), do: decode_single_string(data)

  # area_changed (57): Int8 + Int8
  defp decode_server_packet(57, <<x::8, y::8, rest::binary>>),
    do: {:ok, %{x: x, y: y}, rest}

  # rain_toggle (59): Bool
  defp decode_server_packet(59, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # create_fx (60): Int16 + Int16 + Int16
  defp decode_server_packet(60, <<ci::little-signed-16, fx::little-signed-16, loops::little-signed-16, rest::binary>>),
    do: {:ok, %{char_index: ci, fx_id: fx, loops: loops}, rest}

  # update_user_stats (61): 34 bytes
  defp decode_server_packet(61, <<_::binary-size(34), rest::binary>>), do: {:ok, %{}, rest}

  # change_inventory_slot (63): 1+2+2+1+4+1+4+1 = 16 bytes
  defp decode_server_packet(63, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
      _equipped::8, _valor::little-float-32, _puede_usar::8, _elemental_tags::little-signed-32,
      _is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, obj_index: obj_index, amount: amount}, rest}
  end

  # change_bank_slot (65): same layout
  defp decode_server_packet(65, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
      _equipped::8, _valor::little-float-32, _puede_usar::8, _elemental_tags::little-signed-32,
      _is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, obj_index: obj_index, amount: amount}, rest}
  end

  # change_spell_slot (66): Int8 + Int16 + Int16 + Bool = 6 bytes
  defp decode_server_packet(66, <<slot::8, spell_id::little-signed-16, index::little-signed-16, is_bindable::8, rest::binary>>),
    do: {:ok, %{slot: slot, spell_id: spell_id, index: index, is_bindable: is_bindable != 0}, rest}

  # error_msg (73): string8
  defp decode_server_packet(73, data), do: decode_single_string(data)

  # blind (74): Bool
  defp decode_server_packet(74, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # dumb (75): Bool
  defp decode_server_packet(75, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # snow_toggle (76): Bool
  defp decode_server_packet(76, <<_::8, rest::binary>>), do: {:ok, %{}, rest}

  # change_npc_inventory_slot (77): same layout as inventory
  defp decode_server_packet(77, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
      _equipped::8, _valor::little-float-32, _puede_usar::8, _elemental_tags::little-signed-32,
      _is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, obj_index: obj_index, amount: amount}, rest}
  end

  # hunger_thirst (78): 4 × Int8
  defp decode_server_packet(78, <<max_thirst::8, min_thirst::8, max_hunger::8, min_hunger::8, rest::binary>>),
    do: {:ok, %{max_thirst: max_thirst, min_thirst: min_thirst, max_hunger: max_hunger, min_hunger: min_hunger}, rest}

  # mini_stats (79): 28 bytes
  defp decode_server_packet(79, <<_::binary-size(28), rest::binary>>), do: {:ok, %{}, rest}

  # level_up (80): Int16
  defp decode_server_packet(80, <<level::little-16, rest::binary>>), do: {:ok, %{level: level}, rest}

  # send_atributes (81): 5 bytes
  defp decode_server_packet(81, <<_::binary-size(5), rest::binary>>), do: {:ok, %{}, rest}

  # send_skills (87): 24 bytes
  defp decode_server_packet(87, <<skills::binary-size(24), rest::binary>>), do: {:ok, %{skills: skills}, rest}

  # guild_news (89): string8
  defp decode_server_packet(89, data), do: decode_single_string(data)

  # guild_leader_info (94): string8
  defp decode_server_packet(94, data), do: decode_single_string(data)

  # guild_details (95): string8
  defp decode_server_packet(95, data), do: decode_single_string(data)

  # change_user_trade_slot (100): same layout as inventory
  defp decode_server_packet(100, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
      _equipped::8, _valor::little-float-32, _puede_usar::8, _elemental_tags::little-signed-32,
      _is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, obj_index: obj_index, amount: amount}, rest}
  end

  # intervals (158): 12 × Int32 = 48 bytes
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

  # update_bank_gold (175): Int32
  defp decode_server_packet(175, <<gold::little-signed-32, rest::binary>>),
    do: {:ok, %{gold: gold}, rest}

  # session_token (200): Int32 + string8
  defp decode_server_packet(200, data) do
    with {:ok, char_id, rest} <- Reader.read_int32(data),
         {:ok, token, rest} <- Reader.read_string8(rest) do
      {:ok, %{char_id: char_id, token: token}, rest}
    else
      _ -> :incomplete
    end
  end

  # guild_config (201): string8
  defp decode_server_packet(201, data), do: decode_single_string(data)

  # Catch-all: unknown packet — stop decoding
  defp decode_server_packet(_id, _rest), do: :incomplete

  # -- Helper for single-string packets --
  defp decode_single_string(data) do
    with {:ok, msg, rest} <- Reader.read_string8(data) do
      {:ok, %{message: msg}, rest}
    else
      _ -> :incomplete
    end
  end
end
