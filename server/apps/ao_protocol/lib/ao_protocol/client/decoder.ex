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

  # RequestAccountState (ID 41)
  defp decode_packet(41, rest), do: {:ok, {:request_account_state, %{}}, rest}

  # PetStand (ID 42)
  defp decode_packet(42, rest), do: {:ok, {:pet_stand, %{}}, rest}

  # PetFollow (ID 43)
  defp decode_packet(43, rest), do: {:ok, {:pet_follow, %{}}, rest}

  # PetLeave (ID 44)
  defp decode_packet(44, rest), do: {:ok, {:pet_leave, %{}}, rest}

  # TrainList (ID 46)
  defp decode_packet(46, rest), do: {:ok, {:train_list, %{}}, rest}

  # Help (ID 51)
  defp decode_packet(51, rest), do: {:ok, {:help, %{}}, rest}

  # RequestStats (ID 52)
  defp decode_packet(52, rest), do: {:ok, {:request_stats, %{}}, rest}

  # Information (ID 55)
  defp decode_packet(55, rest), do: {:ok, {:information, %{}}, rest}

  # Reward (ID 56)
  defp decode_packet(56, rest), do: {:ok, {:reward, %{}}, rest}

  # RequestMOTD (ID 57)
  defp decode_packet(57, rest), do: {:ok, {:request_motd, %{}}, rest}

  # UpTime (ID 58)
  defp decode_packet(58, rest), do: {:ok, {:uptime, %{}}, rest}

  # RoleMasterRequest (ID 63) — request(S8)
  defp decode_packet(63, rest) do
    with {:ok, request, rest} <- Reader.read_string8(rest) do
      {:ok, {:role_master_request, %{request: request}}, rest}
    end
  end

  # LeaveFaction (ID 69)
  defp decode_packet(69, rest), do: {:ok, {:leave_faction, %{}}, rest}

  # Home (ID 264) — /HOGAR binary packet, no payload
  defp decode_packet(264, rest), do: {:ok, {:home, %{}}, rest}

  # PetLeaveAll (ID 282) — no payload
  defp decode_packet(282, rest), do: {:ok, {:pet_leave_all, %{}}, rest}

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

  # --- Guild UI packets ---

  # eCreateNewGuild=3 — desc(S8) + name(S8) + alignment(I8)
  defp decode_packet(3, rest) do
    with {:ok, desc, rest} <- Reader.read_string8(rest),
         {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, alignment, rest} <- Reader.read_int8(rest) do
      {:ok, {:guild_create, %{description: desc, name: name, alignment: alignment}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildAcceptPeace=17 — guild(S8)
  defp decode_packet(17, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_accept_peace, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildRejectAlliance=18 — guild(S8)
  defp decode_packet(18, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_reject_alliance, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildRejectPeace=19 — guild(S8)
  defp decode_packet(19, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_reject_peace, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildAcceptAlliance=20 — guild(S8)
  defp decode_packet(20, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_accept_alliance, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildOfferPeace=21 — guild(S8) + proposal(S8)
  defp decode_packet(21, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest),
         {:ok, proposal, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_offer_peace, %{guild: guild, proposal: proposal}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildOfferAlliance=22 — guild(S8) + proposal(S8)
  defp decode_packet(22, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest),
         {:ok, proposal, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_offer_alliance, %{guild: guild, proposal: proposal}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildAllianceDetails=23 — guild(S8)
  defp decode_packet(23, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_alliance_details, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildPeaceDetails=24 — guild(S8)
  defp decode_packet(24, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_peace_details, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildRequestJoinerInfo=25 — username(S8)
  defp decode_packet(25, rest) do
    with {:ok, username, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_request_joiner_info, %{username: username}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildAlliancePropList=26 (no payload)
  defp decode_packet(26, rest), do: {:ok, {:guild_alliance_prop_list, %{}}, rest}

  # eGuildPeacePropList=27 (no payload)
  defp decode_packet(27, rest), do: {:ok, {:guild_peace_prop_list, %{}}, rest}

  # eGuildDeclareWar=28 — guild(S8)
  defp decode_packet(28, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_declare_war, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildNewWebsite=29 — website(S8)
  defp decode_packet(29, rest) do
    with {:ok, website, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_new_website, %{website: website}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildAcceptNewMember=30 — username(S8)
  defp decode_packet(30, rest) do
    with {:ok, username, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_accept_new_member, %{username: username}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildRejectNewMember=31 — username(S8) + reason(S8)
  defp decode_packet(31, rest) do
    with {:ok, username, rest} <- Reader.read_string8(rest),
         {:ok, reason, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_reject_new_member, %{username: username, reason: reason}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildKickMember=32 — username(S8)
  defp decode_packet(32, rest) do
    with {:ok, username, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_kick_member, %{username: username}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildUpdateNews=33 — news(S8)
  defp decode_packet(33, rest) do
    with {:ok, news, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_update_news, %{news: news}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildMemberInfo=34 — username(S8)
  defp decode_packet(34, rest) do
    with {:ok, username, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_member_info, %{username: username}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildOpenElections=35 (no payload)
  defp decode_packet(35, rest), do: {:ok, {:guild_open_elections, %{}}, rest}

  # eGuildRequestMembership=36 — guild(S8) + application(S8)
  defp decode_packet(36, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest),
         {:ok, application, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_request_membership, %{guild: guild, application: application}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildRequestDetails=37 — guild(S8)
  defp decode_packet(37, rest) do
    with {:ok, guild, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_request_details, %{guild: guild}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildLeave=40 (no payload)
  defp decode_packet(40, rest), do: {:ok, {:guild_leave, %{}}, rest}

  # eGuildMessage=59 — chat(S8) + packet_counter(I32)
  defp decode_packet(59, rest) do
    with {:ok, chat, rest} <- Reader.read_string8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:guild_message, %{message: chat}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eGuildOnline=60 (no payload)
  defp decode_packet(60, rest), do: {:ok, {:guild_online, %{}}, rest}

  # eGuildVote=65 — vote(S8)
  defp decode_packet(65, rest) do
    with {:ok, vote, rest} <- Reader.read_string8(rest) do
      {:ok, {:guild_vote, %{vote: vote}}, rest}
    else
      _ -> :incomplete
    end
  end

  # eRequestGuildLeaderInfo=84 (no payload)
  defp decode_packet(84, rest), do: {:ok, {:request_guild_leader_info, %{}}, rest}

  # ---- Crafting, training, skills, spells ----

  # CraftCarpenter (ID 1) — item(I16) + cantidad(I32)
  defp decode_packet(1, rest) do
    with {:ok, item, rest} <- Reader.read_int16(rest),
         {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:craft_carpenter, %{item: item, amount: amount}}, rest}
    end
  end

  # WorkLeftClick (ID 2) — x(I8) + y(I8) + skill(I8) + packet_count(I32)
  defp decode_packet(2, rest) do
    with {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, skill, rest} <- Reader.read_int8(rest),
         {:ok, _packet_count, rest} <- Reader.read_int32(rest) do
      {:ok, {:work_left_click, %{x: x, y: y, skill: skill}}, rest}
    end
  end

  # SpellInfo (ID 4) — slot(I8)
  defp decode_packet(4, rest) do
    with {:ok, slot, rest} <- Reader.read_int8(rest) do
      {:ok, {:spell_info, %{slot: slot}}, rest}
    end
  end

  # ModifySkills (ID 7) — 24 × I8 (NUMSKILLS=24 in VB6)
  defp decode_packet(7, rest) do
    case read_skill_points(rest, 24, []) do
      {:ok, points, rest} -> {:ok, {:modify_skills, %{points: points}}, rest}
      :incomplete -> :incomplete
    end
  end

  # Train (ID 8) — pet_index(I8)
  defp decode_packet(8, rest) do
    with {:ok, pet_index, rest} <- Reader.read_int8(rest) do
      {:ok, {:train, %{pet_index: pet_index}}, rest}
    end
  end

  # ForumPost (ID 13) — title(S8) + message(S8)
  defp decode_packet(13, rest) do
    with {:ok, title, rest} <- Reader.read_string8(rest),
         {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:forum_post, %{title: title, message: message}}, rest}
    end
  end

  # MoveSpell (ID 14) — upwards(Bool) + slot(I8)
  defp decode_packet(14, rest) do
    with {:ok, upwards, rest} <- Reader.read_bool(rest),
         {:ok, slot, rest} <- Reader.read_int8(rest) do
      {:ok, {:move_spell, %{upwards: upwards, slot: slot}}, rest}
    end
  end

  # ClanCodexUpdate (ID 15) — desc(S8)
  defp decode_packet(15, rest) do
    with {:ok, desc, rest} <- Reader.read_string8(rest) do
      {:ok, {:clan_codex_update, %{description: desc}}, rest}
    end
  end

  # GrupoMsg (ID 45) — message(S8)
  defp decode_packet(45, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:grupo_msg, %{message: message}}, rest}
    end
  end

  # CouncilMessage (ID 61) — message(S8)
  defp decode_packet(61, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:council_message, %{message: message}}, rest}
    end
  end

  # FactionMessage (ID 62) — message(S8)
  defp decode_packet(62, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:faction_message, %{message: message}}, rest}
    end
  end

  # ChangeDescription (ID 64) — desc(S8)
  defp decode_packet(64, rest) do
    with {:ok, desc, rest} <- Reader.read_string8(rest) do
      {:ok, {:change_description, %{description: desc}}, rest}
    end
  end

  # Punishments (ID 66) — name(S8)
  defp decode_packet(66, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:punishments, %{name: name}}, rest}
    end
  end

  # Forgive (ID 68) — no payload
  defp decode_packet(68, rest), do: {:ok, {:forgive, %{}}, rest}

  # Gamble (ID 67) — amount(I32)
  defp decode_packet(67, rest) do
    with {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:gamble, %{amount: amount}}, rest}
    end
  end

  # Denounce (ID 72) — name(S8) + reason(S8)
  defp decode_packet(72, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, reason, rest} <- Reader.read_string8(rest) do
      {:ok, {:denounce, %{name: name, reason: reason}}, rest}
    end
  end

  # CraftBlacksmith (ID 100) — item(I16)
  defp decode_packet(100, rest) do
    with {:ok, item, rest} <- Reader.read_int16(rest) do
      {:ok, {:craft_blacksmith, %{item: item}}, rest}
    end
  end

  # CraftAlquimista (ID 228) — item(I16)
  defp decode_packet(228, rest) do
    with {:ok, item, rest} <- Reader.read_int16(rest) do
      {:ok, {:craft_alchemy, %{item: item}}, rest}
    end
  end

  # CraftSastre (ID 230) — item(I16)
  defp decode_packet(230, rest) do
    with {:ok, item, rest} <- Reader.read_int16(rest) do
      {:ok, {:craft_tailor, %{item: item}}, rest}
    end
  end

  # ---- GM packets (core subset) ----

  # GMMessage (ID 101) — message(S8)
  defp decode_packet(101, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:gm_message, %{message: message}}, rest}
    end
  end

  # Where (ID 107) — name(S8)
  defp decode_packet(107, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:where, %{name: name}}, rest}
    end
  end

  # WarpMeToTarget (ID 109)
  defp decode_packet(109, rest), do: {:ok, {:warp_me_to_target, %{}}, rest}

  # WarpChar (ID 110) — name(S8) + map(I16)
  defp decode_packet(110, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, map, rest} <- Reader.read_int16(rest) do
      {:ok, {:warp_char, %{name: name, map: map}}, rest}
    end
  end

  # Silence (ID 111) — name(S8)
  defp decode_packet(111, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:silence, %{name: name}}, rest}
    end
  end

  # GoToChar (ID 114) — name(S8)
  defp decode_packet(114, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:go_to_char, %{name: name}}, rest}
    end
  end

  # Invisible (ID 115)
  defp decode_packet(115, rest), do: {:ok, {:invisible, %{}}, rest}

  # Jail (ID 120) — name(S8) + reason(S8) + minutes(I8)
  defp decode_packet(120, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, reason, rest} <- Reader.read_string8(rest),
         {:ok, minutes, rest} <- Reader.read_int8(rest) do
      {:ok, {:jail, %{name: name, reason: reason, minutes: minutes}}, rest}
    end
  end

  # KillNPC (ID 121)
  defp decode_packet(121, rest), do: {:ok, {:kill_npc, %{}}, rest}

  # RequestCharInfo (ID 124) — name(S8)
  defp decode_packet(124, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:request_char_info, %{name: name}}, rest}
    end
  end

  # ReviveChar (ID 130) — name(S8)
  defp decode_packet(130, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:revive_char, %{name: name}}, rest}
    end
  end

  # OnlineGM (ID 131)
  defp decode_packet(131, rest), do: {:ok, {:online_gm, %{}}, rest}

  # OnlineRoyalArmy (ID 132) — no payload
  defp decode_packet(132, rest), do: {:ok, {:online_royal_army, %{}}, rest}

  # OnlineChaosLegion (ID 133) — no payload
  defp decode_packet(133, rest), do: {:ok, {:online_chaos_legion, %{}}, rest}

  # Kick (ID 134) — name(S8)
  defp decode_packet(134, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:kick, %{name: name}}, rest}
    end
  end

  # Execute (ID 135) — name(S8)
  defp decode_packet(135, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:execute, %{name: name}}, rest}
    end
  end

  # BanChar (ID 136) — name(S8) + reason(S8)
  defp decode_packet(136, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, reason, rest} <- Reader.read_string8(rest) do
      {:ok, {:ban_char, %{name: name, reason: reason}}, rest}
    end
  end

  # UnbanChar (ID 137) — name(S8)
  defp decode_packet(137, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:unban_char, %{name: name}}, rest}
    end
  end

  # SummonChar (ID 139) — name(S8)
  defp decode_packet(139, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:summon_char, %{name: name}}, rest}
    end
  end

  # ServerMessage (ID 144) — message(S8)
  defp decode_packet(144, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:server_message, %{message: message}}, rest}
    end
  end

  # RainToggle (ID 150)
  defp decode_packet(150, rest), do: {:ok, {:rain_toggle, %{}}, rest}

  # ---- Batch 2: NPC Management GM packets ----

  # CreaturesInMap (ID 326) — map(I16)
  defp decode_packet(326, rest) do
    with {:ok, map, rest} <- Reader.read_int16(rest) do
      {:ok, {:creatures_in_map, %{map: map}}, rest}
    end
  end

  # KillNPCTargeted (ID 339) — no payload (kills NPC at target, allows respawn)
  defp decode_packet(339, rest), do: {:ok, {:kill_npc_targeted, %{}}, rest}

  # SpawnListRequest (ID 358) — no payload
  defp decode_packet(358, rest), do: {:ok, {:spawn_list_request, %{}}, rest}

  # SpawnCreature (ID 359) — creature_id(I16)
  defp decode_packet(359, rest) do
    with {:ok, creature_id, rest} <- Reader.read_int16(rest) do
      {:ok, {:spawn_creature, %{creature_id: creature_id}}, rest}
    end
  end

  # KillNPCNoRespawn (ID 394) — no payload
  defp decode_packet(394, rest), do: {:ok, {:kill_npc_no_respawn, %{}}, rest}

  # KillAllNearbyNPCs (ID 395) — no payload
  defp decode_packet(395, rest), do: {:ok, {:kill_all_nearby_npcs, %{}}, rest}

  # CreateNPC (ID 399) — npc_id(I16)
  defp decode_packet(399, rest) do
    with {:ok, npc_id, rest} <- Reader.read_int16(rest) do
      {:ok, {:create_npc, %{npc_id: npc_id}}, rest}
    end
  end

  # CreateNPCWithRespawn (ID 400) — npc_id(I16)
  defp decode_packet(400, rest) do
    with {:ok, npc_id, rest} <- Reader.read_int16(rest) do
      {:ok, {:create_npc_with_respawn, %{npc_id: npc_id}}, rest}
    end
  end

  # ---- Batch 3: Character Management GM packets ----

  # EditChar (ID 341) — name(S8) + option(I8) + arg1(S8) + arg2(S8)
  defp decode_packet(341, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, option, rest} <- Reader.read_int8(rest),
         {:ok, arg1, rest} <- Reader.read_string8(rest),
         {:ok, arg2, rest} <- Reader.read_string8(rest) do
      {:ok, {:edit_char, %{name: name, option: option, arg1: arg1, arg2: arg2}}, rest}
    end
  end

  # RequestCharStats (ID 343) — name(S8)
  defp decode_packet(343, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:request_char_stats, %{name: name}}, rest}
    end
  end

  # RequestCharGold (ID 344) — name(S8)
  defp decode_packet(344, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:request_char_gold, %{name: name}}, rest}
    end
  end

  # RequestCharInventory (ID 345) — name(S8)
  defp decode_packet(345, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:request_char_inventory, %{name: name}}, rest}
    end
  end

  # RequestCharBank (ID 346) — name(S8)
  defp decode_packet(346, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:request_char_bank, %{name: name}}, rest}
    end
  end

  # RequestCharSkills (ID 347) — name(S8)
  defp decode_packet(347, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest) do
      {:ok, {:request_char_skills, %{name: name}}, rest}
    end
  end

  # CreateItem (ID 386) — item_id(I16) + amount(I16)
  defp decode_packet(386, rest) do
    with {:ok, item_id, rest} <- Reader.read_int16(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest) do
      {:ok, {:create_item, %{item_id: item_id, amount: amount}}, rest}
    end
  end

  # AlterName (ID 405) — name(S8) + new_name(S8)
  defp decode_packet(405, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, new_name, rest} <- Reader.read_string8(rest) do
      {:ok, {:alter_name, %{name: name, new_name: new_name}}, rest}
    end
  end

  # GiveItem (ID 430) — name(S8) + item_id(I16) + amount(I16) + reason(S8)
  defp decode_packet(430, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, item_id, rest} <- Reader.read_int16(rest),
         {:ok, amount, rest} <- Reader.read_int16(rest),
         {:ok, reason, rest} <- Reader.read_string8(rest) do
      {:ok, {:give_item, %{name: name, item_id: item_id, amount: amount, reason: reason}}, rest}
    end
  end

  # ---- Batch 1: Essential Server Admin GM packets ----

  # Online (ID 255) — no payload
  defp decode_packet(255, rest), do: {:ok, {:online, %{}}, rest}

  # OnlineMap (ID 350) — no payload
  defp decode_packet(350, rest), do: {:ok, {:online_map, %{}}, rest}

  # ServerOpenToggle (ID 402) — no payload
  defp decode_packet(402, rest), do: {:ok, {:server_open_toggle, %{}}, rest}

  # SaveChars (ID 417) — no payload
  defp decode_packet(417, rest), do: {:ok, {:save_chars, %{}}, rest}

  # KickAllChars (ID 420) — no payload
  defp decode_packet(420, rest), do: {:ok, {:kick_all_chars, %{}}, rest}

  # GlobalMessage (ID 425) — message(S8)
  defp decode_packet(425, rest) do
    with {:ok, message, rest} <- Reader.read_string8(rest) do
      {:ok, {:global_message, %{message: message}}, rest}
    end
  end

  # DonateGold (ID 210) — amount(I32)
  defp decode_packet(210, rest) do
    with {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:donate_gold, %{amount: amount}}, rest}
    end
  end

  # TransferGold (ID 224) — name(S8) + amount(I32)
  defp decode_packet(224, rest) do
    with {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:transfer_gold, %{name: name, amount: amount}}, rest}
    end
  end

  # MoveItem (ID 225) — from_slot(I8) + to_slot(I8)
  defp decode_packet(225, rest) do
    with {:ok, from_slot, rest} <- Reader.read_int8(rest),
         {:ok, to_slot, rest} <- Reader.read_int8(rest) do
      {:ok, {:move_item, %{from_slot: from_slot, to_slot: to_slot}}, rest}
    end
  end

  # QuestionGM (ID 215) — consulta(S8) + tipo(S8) + packet_counter(I32)
  defp decode_packet(215, rest) do
    with {:ok, consulta, rest} <- Reader.read_string8(rest),
         {:ok, tipo, rest} <- Reader.read_string8(rest),
         {:ok, _packet_counter, rest} <- Reader.read_int32(rest) do
      {:ok, {:question_gm, %{consulta: consulta, tipo: tipo}}, rest}
    end
  end

  # --- Auction packets ---

  # eOfertaInicial (ID 213) — Int32 amount
  defp decode_packet(213, rest) do
    with {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:oferta_inicial, %{amount: amount}}, rest}
    end
  end

  # eOfertaDeSubasta (ID 214) — Int32 amount
  defp decode_packet(214, rest) do
    with {:ok, amount, rest} <- Reader.read_int32(rest) do
      {:ok, {:oferta_de_subasta, %{amount: amount}}, rest}
    end
  end

  # eSubastaInfo (ID 240) — no payload
  defp decode_packet(240, rest), do: {:ok, {:subasta_info, %{}}, rest}

  # ArenaEntry (ID 259) — no payload
  defp decode_packet(259, rest), do: {:ok, {:arena_entry, %{}}, rest}

  # Unknown packet
  defp decode_packet(id, _rest), do: {:error, {:unknown_packet, id}}

  # ---- Helpers ----

  # Read NUMSKILLS (24) bytes for ModifySkills
  defp read_skill_points(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_skill_points(rest, n, acc) do
    case Reader.read_int8(rest) do
      {:ok, val, rest} -> read_skill_points(rest, n - 1, [val | acc])
      :incomplete -> :incomplete
    end
  end

  # Helper: conditionally read skin_type byte for EquipItem
  defp maybe_read_skin_type(true, rest), do: Reader.read_int8(rest)
  defp maybe_read_skin_type(false, rest), do: {:ok, 0, rest}
end
