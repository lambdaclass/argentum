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

  # Talk (ID 75)
  defp decode_packet(75, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:talk, %{message: message}}, rest}
    end
  end

  # Yell (ID 76)
  defp decode_packet(76, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:yell, %{message: message}}, rest}
    end
  end

  # Whisper (ID 77)
  defp decode_packet(77, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:whisper, %{message: message}}, rest}
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

  # Attack (ID 80)
  defp decode_packet(80, rest), do: {:ok, {:attack, %{}}, rest}

  # CastSpell (ID 94)
  defp decode_packet(94, rest) do
    with {:ok, spell_slot, rest} <- Reader.read_int8(rest) do
      {:ok, {:cast_spell, %{spell_slot: spell_slot}}, rest}
    end
  end

  # PickUp (ID 81)
  defp decode_packet(81, rest), do: {:ok, {:pick_up, %{}}, rest}

  # Drop (ID 93)
  defp decode_packet(93, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest) do
      {:ok, {:drop, %{slot: slot, amount: amount}}, rest}
    end
  end

  # SafeToggle (ID 82)
  defp decode_packet(82, rest), do: {:ok, {:safe_toggle, %{}}, rest}

  # EquipItem (ID 5)
  defp decode_packet(5, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest) do
      {:ok, {:equip_item, %{slot: slot}}, rest}
    end
  end

  # ChangeHeading (ID 6)
  defp decode_packet(6, rest) do
    with {:ok, heading, rest} <- Reader.read_int8(rest) do
      {:ok, {:change_heading, %{heading: heading}}, rest}
    end
  end

  # Quit (ID 39)
  defp decode_packet(39, rest), do: {:ok, {:quit, %{}}, rest}

  # UseItem (ID 99)
  defp decode_packet(99, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest) do
      {:ok, {:use_item, %{slot: slot}}, rest}
    end
  end

  # LeftClick (ID 95)
  defp decode_packet(95, rest) do
    with {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest) do
      {:ok, {:left_click, %{x: x, y: y}}, rest}
    end
  end

  # Unknown packet
  defp decode_packet(id, _rest), do: {:error, {:unknown_packet, id}}
end
