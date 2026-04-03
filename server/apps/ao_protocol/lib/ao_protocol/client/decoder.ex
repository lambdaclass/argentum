defmodule AoProtocol.Client.Decoder do
  @moduledoc """
  Decodes client→server binary packets into command tuples.

  Each packet starts with an Int16 packet_id. The decoder reads the ID,
  then dispatches to the appropriate field parser based on the packet schema.

  Returns `{:ok, command, rest}` or `:incomplete` or `{:error, reason}`.
  """

  alias AoProtocol.Reader

  @doc "Decode one packet from a binary buffer."
  def decode(data) when byte_size(data) < 2, do: :incomplete

  def decode(data) do
    case Reader.read_packet_id(data) do
      {:ok, packet_id, rest} -> decode_packet(packet_id, rest)
      :incomplete -> :incomplete
    end
  end

  # LoginExistingChar (ID 73)
  # AO20 format: encrypted_session_token(String8) + char_id(Int32) + version(3xInt8) + md5(String8)
  defp decode_packet(73, rest) do
    with {:ok, session_token, rest} <- Reader.read_string8(rest),
         {:ok, char_id, rest} <- Reader.read_int32(rest),
         {:ok, version_major, rest} <- Reader.read_int8(rest),
         {:ok, version_minor, rest} <- Reader.read_int8(rest),
         {:ok, version_build, rest} <- Reader.read_int8(rest),
         {:ok, md5, rest} <- Reader.read_string8(rest) do
      {:ok,
       {:login_existing_char,
        %{
          session_token: session_token,
          char_id: char_id,
          version: "#{version_major}.#{version_minor}.#{version_build}",
          md5: md5
        }}, rest}
    end
  end

  # LoginNewChar (ID 74)
  # AO20 format: encrypted_session_token(String8) + encrypted_username(String8) + version(3xInt8) + md5(String8)
  #              + race(Int8) + gender(Int8) + class(Int8) + head(Int16) + home_city(Int8)
  defp decode_packet(74, rest) do
    with {:ok, session_token, rest} <- Reader.read_string8(rest),
         {:ok, username, rest} <- Reader.read_string8(rest),
         {:ok, version_major, rest} <- Reader.read_int8(rest),
         {:ok, version_minor, rest} <- Reader.read_int8(rest),
         {:ok, version_build, rest} <- Reader.read_int8(rest),
         {:ok, md5, rest} <- Reader.read_string8(rest),
         {:ok, race, rest} <- Reader.read_int8(rest),
         {:ok, gender, rest} <- Reader.read_int8(rest),
         {:ok, class, rest} <- Reader.read_int8(rest),
         {:ok, head, rest} <- Reader.read_int16(rest),
         {:ok, home_city, rest} <- Reader.read_int8(rest) do
      {:ok,
       {:login_new_char,
        %{
          session_token: session_token,
          username: username,
          version: "#{version_major}.#{version_minor}.#{version_build}",
          md5: md5,
          race: race,
          gender: gender,
          class: class,
          head: head,
          home_city: home_city
        }}, rest}
    end
  end

  # Talk (ID 75) — message(String8) + packet_count(Int32)
  defp decode_packet(75, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:talk, %{message: message}}, rest}
    end
  end

  # Yell (ID 76)
  defp decode_packet(76, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:yell, %{message: message}}, rest}
    end
  end

  # Whisper (ID 77) — target_name(String8) + message(String8)
  defp decode_packet(77, rest) do
    with {:ok, target_name, rest} <- Reader.read_string8(rest),
         {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:whisper, %{target_name: target_name, message: message}}, rest}
    end
  end

  # Walk (ID 78)
  defp decode_packet(78, rest) do
    with {:ok, heading, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      direction =
        case heading do
          1 -> :north
          2 -> :east
          3 -> :south
          4 -> :west
          _ -> :north
        end

      {:ok, {:walk, %{direction: direction}}, rest}
    end
  end

  # RequestPositionUpdate (ID 79)
  defp decode_packet(79, rest), do: {:ok, {:request_position_update, %{}}, rest}

  # Attack (ID 80) — packet_count(Int32)
  defp decode_packet(80, rest) do
    with {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:attack, %{}}, rest}
    end
  end

  # CastSpell (ID 94) — slot(Int8) + packet_count(Int32)
  defp decode_packet(94, rest) do
    with {:ok, spell_slot, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:cast_spell, %{spell_slot: spell_slot}}, rest}
    end
  end

  # PickUp (ID 81)
  defp decode_packet(81, rest), do: {:ok, {:pick_up, %{}}, rest}

  # Drop (ID 93) — slot(Int8) + amount(Int32) + packet_count(Int32)
  defp decode_packet(93, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, amount, rest} <- Reader.read_int32(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:drop, %{slot: slot, amount: amount}}, rest}
    end
  end

  # SafeToggle (ID 82)
  defp decode_packet(82, rest), do: {:ok, {:safe_toggle, %{}}, rest}

  # EquipItem (ID 5) — slot(Int8) + is_skin(Bool) + [skin_type(Int8)] + packet_count(Int32)
  defp decode_packet(5, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, is_skin, rest} <- Reader.read_bool(rest),
         {:ok, _skin_type, rest} <- maybe_read_skin_type(is_skin, rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:equip_item, %{slot: slot}}, rest}
    end
  end

  # ChangeHeading (ID 6) — heading(Int8) + packet_count(Int32)
  defp decode_packet(6, rest) do
    with {:ok, heading, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:change_heading, %{heading: heading}}, rest}
    end
  end

  # Quit (ID 39)
  defp decode_packet(39, rest), do: {:ok, {:quit, %{}}, rest}

  # UseItem (ID 99) — slot(Int8) + is_main_inventory(Int8) + packet_count(Int32)
  defp decode_packet(99, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, _is_main_inventory, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:use_item, %{slot: slot}}, rest}
    end
  end

  # LeftClick (ID 95) — x(Int8) + y(Int8) + packet_count(Int32)
  defp decode_packet(95, rest) do
    with {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:left_click, %{x: x, y: y}}, rest}
    end
  end

  # CommerceStart (ID 53) — no payload
  defp decode_packet(53, rest), do: {:ok, {:commerce_start, %{}}, rest}

  # CommerceBuy (ID 9) — slot(Int8) + amount(Int16)
  defp decode_packet(9, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest) do
      {:ok, {:commerce_buy, %{slot: slot, amount: amount}}, rest}
    end
  end

  # CommerceSell (ID 11) — slot(Int8) + amount(Int16)
  defp decode_packet(11, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest) do
      {:ok, {:commerce_sell, %{slot: slot, amount: amount}}, rest}
    end
  end

  # CommerceEnd (ID 88) — no payload
  defp decode_packet(88, rest), do: {:ok, {:commerce_end, %{}}, rest}

  # BankEnd (ID 90) — no payload
  defp decode_packet(90, rest), do: {:ok, {:bank_end, %{}}, rest}

  # ---- No-payload packets (VB6 client sends these, must consume cleanly) ----

  # Online (ID 38)
  defp decode_packet(38, rest), do: {:ok, {:online, %{}}, rest}

  # Rest (ID 47)
  defp decode_packet(47, rest), do: {:ok, {:rest, %{}}, rest}

  # Meditate (ID 48)
  defp decode_packet(48, rest), do: {:ok, {:meditate, %{}}, rest}

  # Resucitate (ID 49)
  defp decode_packet(49, rest), do: {:ok, {:resucitate, %{}}, rest}

  # Heal (ID 50)
  defp decode_packet(50, rest), do: {:ok, {:heal, %{}}, rest}

  # PartySafeToggle (ID 83)
  defp decode_packet(83, rest), do: {:ok, {:party_safe_toggle, %{}}, rest}

  # RequestAtributes (ID 85)
  defp decode_packet(85, rest), do: {:ok, {:request_atributes, %{}}, rest}

  # RequestSkills (ID 86)
  defp decode_packet(86, rest), do: {:ok, {:request_skills, %{}}, rest}

  # RequestMiniStats (ID 87)
  defp decode_packet(87, rest), do: {:ok, {:request_mini_stats, %{}}, rest}

  # UseSpellMacro (ID 98)
  defp decode_packet(98, rest), do: {:ok, {:use_spell_macro, %{}}, rest}

  # BankStart (ID 54)
  defp decode_packet(54, rest), do: {:ok, {:bank_start, %{}}, rest}

  # ---- Packets with payloads ----

  # DoubleClick (ID 96) — x(Int8) + y(Int8)
  defp decode_packet(96, rest) do
    with {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest) do
      {:ok, {:double_click, %{x: x, y: y}}, rest}
    end
  end

  # Work (ID 97) — skill(Int8) + packet_count(Int32)
  defp decode_packet(97, rest) do
    with {:ok, skill, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:work, %{skill: skill}}, rest}
    end
  end

  # BankExtractItem (ID 10) — slot(Int8) + amount(Int16) + slot_destino(Int8)
  defp decode_packet(10, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest),
         {:ok, slot_destino, rest} <- Reader.read_int8(rest) do
      {:ok, {:bank_extract_item, %{slot: slot, amount: amount, slot_destino: slot_destino}}, rest}
    end
  end

  # BankDeposit (ID 12) — slot(Int8) + amount(Int16) + slot_destino(Int8)
  defp decode_packet(12, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest),
         {:ok, slot_destino, rest} <- Reader.read_int8(rest) do
      {:ok, {:bank_deposit, %{slot: slot, amount: amount, slot_destino: slot_destino}}, rest}
    end
  end

  # BankExtractGold (ID 70) — amount(Int32)
  defp decode_packet(70, rest) do
    with {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:bank_extract_gold, %{amount: amount}}, rest}
    end
  end

  # BankDepositGold (ID 71) — amount(Int32)
  defp decode_packet(71, rest) do
    with {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:bank_deposit_gold, %{amount: amount}}, rest}
    end
  end

  # User-to-user commerce (VB6: eUserCommerceOffer=16, obj_index:Int16 + amount:Int32)
  defp decode_packet(16, rest) do
    with {:ok, obj_index, rest} <- Reader.read_int16(rest),
         {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:user_commerce_offer, %{obj_index: obj_index, amount: amount}}, rest}
    end
  end

  # VB6: eUserCommerceEnd=89 (no payload)
  defp decode_packet(89, rest), do: {:ok, {:user_commerce_end, %{}}, rest}

  # VB6: eUserCommerceOk=91 (no payload)
  defp decode_packet(91, rest), do: {:ok, {:user_commerce_ok, %{}}, rest}

  # VB6: eUserCommerceReject=92 (no payload)
  defp decode_packet(92, rest), do: {:ok, {:user_commerce_reject, %{}}, rest}

  # Unknown packet
  defp decode_packet(id, _rest), do: {:error, {:unknown_packet, id}}

  # Helper: conditionally read skin_type byte for EquipItem
  defp maybe_read_skin_type(true, rest), do: Reader.read_int8(rest)
  defp maybe_read_skin_type(false, rest), do: {:ok, 0, rest}
end
