defmodule AoProtocol.Server.Encoder do
  @moduledoc """
  Encodes server→client command tuples into binary packets.
  Matches AO20 Protocol_Writes.bas format exactly.
  """

  alias AoProtocol.Writer
  alias AoProtocol.PacketIds

  @doc "Encode a server command into a binary packet."

  # eConnected (ID 1) — sent on TCP connect
  def encode({:connected, _params}) do
    Writer.build_packet(PacketIds.Server.connected(), <<>>)
  end

  # elogged (ID 2) — newUser: Bool
  def encode({:logged, %{new_user: new_user}}) do
    payload = Writer.write_bool(new_user)
    Writer.build_packet(PacketIds.Server.logged(), payload)
  end

  def encode({:logged, _params}) do
    payload = Writer.write_bool(false)
    Writer.build_packet(PacketIds.Server.logged(), payload)
  end

  # eDisconnect (ID 7)
  def encode({:disconnect, _params}) do
    Writer.build_packet(PacketIds.Server.disconnect(), <<>>)
  end

  # eUserIndexInServer (ID 46) — Int16 user_index
  def encode({:user_index_in_server, %{user_index: user_index}}) do
    payload = Writer.write_int16(user_index)
    Writer.build_packet(PacketIds.Server.user_index_in_server(), payload)
  end

  # eUserCharIndexInServer (ID 47) — Int16 char_index
  def encode({:user_char_index_in_server, %{char_index: char_index}}) do
    payload = Writer.write_int16(char_index)
    Writer.build_packet(PacketIds.Server.user_char_index_in_server(), payload)
  end

  # eChangeMap (ID 30) — Map(Int16) + MapResource(Int16)
  def encode({:change_map, %{map_id: map_id, version: version}}) do
    payload = Writer.write_int16(map_id) <> Writer.write_int16(version)
    Writer.build_packet(PacketIds.Server.change_map(), payload)
  end

  # ePosUpdate (ID 31) — x(Int8) + y(Int8)
  def encode({:pos_update, %{x: x, y: y}}) do
    payload = Writer.write_int8(x) <> Writer.write_int8(y)
    Writer.build_packet(PacketIds.Server.pos_update(), payload)
  end

  # eCharacterCreate (ID 42) — full AO20 format
  def encode({:character_create, params}) do
    payload =
      Writer.write_int16(params[:char_index] || 0) <>
        Writer.write_int16(params[:body_id] || 0) <>
        Writer.write_int16(params[:head_id] || 0) <>
        Writer.write_int8(params[:heading] || 3) <>
        Writer.write_int8(params[:x] || 0) <>
        Writer.write_int8(params[:y] || 0) <>
        Writer.write_int16(params[:weapon_id] || 0) <>
        Writer.write_int16(params[:shield_id] || 0) <>
        Writer.write_int16(params[:helmet_id] || 0) <>
        Writer.write_int16(params[:cart_id] || 0) <>
        Writer.write_int16(params[:backpack_id] || 0) <>
        Writer.write_int16(params[:fx] || 0) <>
        Writer.write_int16(params[:fx_loops] || 0) <>
        Writer.write_string8(params[:name] || "") <>
        Writer.write_int8(params[:status] || 0) <>
        Writer.write_int8(params[:privileges] || 0) <>
        Writer.write_int8(params[:particula_fx] || 0) <>
        Writer.write_string8(params[:head_aura] || "") <>
        Writer.write_string8(params[:arma_aura] || "") <>
        Writer.write_string8(params[:body_aura] || "") <>
        Writer.write_string8(params[:dm_aura] || "") <>
        Writer.write_string8(params[:rm_aura] || "") <>
        Writer.write_string8(params[:otra_aura] || "") <>
        Writer.write_string8(params[:escudo_aura] || "") <>
        Writer.write_real32(params[:speed] || 1.0) <>
        Writer.write_int8(params[:es_npc] || 0) <>
        Writer.write_int8(params[:appear] || 0) <>
        Writer.write_int16(params[:group_index] || 0) <>
        Writer.write_int16(params[:clan_index] || 0) <>
        Writer.write_int8(params[:clan_nivel] || 0) <>
        Writer.write_int32(params[:min_hp] || 0) <>
        Writer.write_int32(params[:max_hp] || 0) <>
        Writer.write_int32(params[:min_mana] || 0) <>
        Writer.write_int32(params[:max_mana] || 0) <>
        Writer.write_int8(params[:simbolo] || 0) <>
        encode_char_flags(params) <>
        Writer.write_int8(params[:tipo_usuario] || 0) <>
        Writer.write_int8(params[:team_captura] || 0) <>
        Writer.write_int8(params[:tiene_bandera] || 0) <>
        Writer.write_int16(params[:npc_num] || 0)

    Writer.build_packet(PacketIds.Server.character_create(), payload)
  end

  # eCharacterChange (ID 49) — full appearance update
  # charindex(Int16) + flags(Int8) + body(Int16) + head(Int16) + heading(Int8)
  # + weapon(Int16) + shield(Int16) + helmet(Int16) + cart(Int16) + backpack(Int16)
  # + fx(Int16) + fx_loops(Int16)
  def encode({:character_change, params}) do
    flags = encode_char_flags(params)

    payload =
      Writer.write_int16(params[:char_index] || 0) <>
        flags <>
        Writer.write_int16(params[:body_id] || 0) <>
        Writer.write_int16(params[:head_id] || 0) <>
        Writer.write_int8(params[:heading] || 3) <>
        Writer.write_int16(params[:weapon_id] || 0) <>
        Writer.write_int16(params[:shield_id] || 0) <>
        Writer.write_int16(params[:helmet_id] || 0) <>
        Writer.write_int16(params[:cart_id] || 0) <>
        Writer.write_int16(params[:backpack_id] || 0) <>
        Writer.write_int16(params[:fx] || 0) <>
        Writer.write_int16(params[:fx_loops] || 0)

    Writer.build_packet(PacketIds.Server.character_change(), payload)
  end

  # eCharacterRemove (ID 43) — charindex(Int16) + desvanecido(Bool) + fue_warp(Bool)
  def encode({:character_remove, params}) do
    payload =
      Writer.write_int16(params[:char_index] || 0) <>
        Writer.write_bool(params[:desvanecido] || false) <>
        Writer.write_bool(params[:fue_warp] || false)

    Writer.build_packet(PacketIds.Server.character_remove(), payload)
  end

  # eCharacterMove (ID 44) — charindex(Int16) + x(Int8) + y(Int8)
  def encode({:character_move, %{char_index: char_index, x: x, y: y}}) do
    payload = Writer.write_int16(char_index) <> Writer.write_int8(x) <> Writer.write_int8(y)
    Writer.build_packet(PacketIds.Server.character_move(), payload)
  end

  # eUpdateHP (ID 27) — MinHp(Int16) + shield(Int32)
  def encode({:update_hp, %{min_hp: min_hp, shield: shield}}) do
    payload = Writer.write_int16(min_hp) <> Writer.write_int32(shield)
    Writer.build_packet(PacketIds.Server.update_hp(), payload)
  end

  def encode({:update_hp, %{min_hp: min_hp}}) do
    payload = Writer.write_int16(min_hp) <> Writer.write_int32(0)
    Writer.build_packet(PacketIds.Server.update_hp(), payload)
  end

  # eUpdateMana (ID 26) — MinMAN(Int16)
  def encode({:update_mana, %{min_mana: min_mana}}) do
    payload = Writer.write_int16(min_mana)
    Writer.build_packet(PacketIds.Server.update_mana(), payload)
  end

  # eUpdateSta (ID 25) — MinSta(Int16)
  def encode({:update_stamina, %{min_sta: min_sta}}) do
    payload = Writer.write_int16(min_sta)
    Writer.build_packet(PacketIds.Server.update_sta(), payload)
  end

  # eUpdateGold (ID 28) — Gold(Int32) + OroPorNivelBilletera(Int32)
  def encode({:update_gold, %{gold: gold}}) do
    payload = Writer.write_int32(gold) <> Writer.write_int32(0)
    Writer.build_packet(PacketIds.Server.update_gold(), payload)
  end

  # eUpdateExp (ID 29) — CurrentXP(Int32) + NextXP(Int32)
  def encode({:update_exp, %{current_xp: current_xp, next_xp: next_xp}}) do
    payload = Writer.write_int32(current_xp) <> Writer.write_int32(next_xp)
    Writer.build_packet(PacketIds.Server.update_exp(), payload)
  end

  # eConsoleMsg (ID 37) — chat(String8) + FontIndex(Int8)
  def encode({:console_msg, %{message: message, font_index: font_index}}) do
    payload = Writer.write_string8(message) <> Writer.write_int8(font_index)
    Writer.build_packet(PacketIds.Server.console_msg(), payload)
  end

  # eConsoleFactionMessage (ID 38) — chat(String8) + font_index(Int8) + faction_label(String8)
  def encode({:console_faction_message, params}) do
    payload =
      Writer.write_string8(params[:message] || "") <>
        Writer.write_int8(params[:font_index] || 0) <>
        Writer.write_string8(params[:faction_label] || "")
    Writer.build_packet(PacketIds.Server.console_faction_message(), payload)
  end

  # eGuildChat (ID 39) — status(Int8) + chat(String8)
  def encode({:guild_chat, params}) do
    payload =
      Writer.write_int8(params[:status] || 0) <>
        Writer.write_string8(params[:message] || "")
    Writer.build_packet(PacketIds.Server.guild_chat(), payload)
  end

  # eguildList (ID 56) — guild_names separated by SEPARATOR
  def encode({:guild_list, params}) do
    payload = Writer.write_string8(params[:guild_names] || "")
    Writer.build_packet(PacketIds.Server.guild_list(), payload)
  end

  # eguildNews (ID 89) — news(S8) + guildList(S8) + memberList(S8) + level(I8) + exp(I16) + expNeeded(I16)
  def encode({:guild_news, params}) do
    payload =
      Writer.write_string8(params[:news] || "") <>
        Writer.write_string8(params[:guild_list] || "") <>
        Writer.write_string8(params[:member_list] || "") <>
        Writer.write_int8(params[:level] || 1) <>
        Writer.write_int16(params[:current_exp] || 0) <>
        Writer.write_int16(params[:needed_exp] || 0)
    Writer.build_packet(PacketIds.Server.guild_news(), payload)
  end

  # eGuildLeaderInfo (ID 94) — guildList(S8) + memberList(S8) + news(S8) + requests(S8) + level(I8) + exp(I16) + expNeeded(I16)
  def encode({:guild_leader_info, params}) do
    payload =
      Writer.write_string8(params[:guild_list] || "") <>
        Writer.write_string8(params[:member_list] || "") <>
        Writer.write_string8(params[:news] || "") <>
        Writer.write_string8(params[:requests] || "") <>
        Writer.write_int8(params[:level] || 1) <>
        Writer.write_int16(params[:current_exp] || 0) <>
        Writer.write_int16(params[:needed_exp] || 0)
    Writer.build_packet(PacketIds.Server.guild_leader_info(), payload)
  end

  # eGuildDetails (ID 95) — name(S8) + founder(S8) + date(S8) + leader(S8) + members(I16) + alignment(S8) + desc(S8) + level(I8)
  def encode({:guild_details, params}) do
    payload =
      Writer.write_string8(params[:name] || "") <>
        Writer.write_string8(params[:founder] || "") <>
        Writer.write_string8(params[:date] || "") <>
        Writer.write_string8(params[:leader] || "") <>
        Writer.write_int16(params[:member_count] || 0) <>
        Writer.write_string8(params[:alignment] || "") <>
        Writer.write_string8(params[:description] || "") <>
        Writer.write_int8(params[:level] || 1)
    Writer.build_packet(PacketIds.Server.guild_details(), payload)
  end

  # eShowGuildFundationForm (ID 96) — no payload
  def encode({:show_guild_fundation_form, _params}) do
    Writer.build_packet(PacketIds.Server.show_guild_fundation_form(), <<>>)
  end

  # eGuildConfig (ID 201) — 5 config bytes + membersByLevel array
  def encode({:guild_config, params}) do
    members_by_level = params[:members_by_level] || [10, 20, 30, 40, 50, 60, 70]
    payload =
      Writer.write_int8(params[:level_call_support] || 3) <>
        Writer.write_int8(params[:level_see_invisible] || 5) <>
        Writer.write_int8(params[:level_safe] || 2) <>
        Writer.write_int8(params[:level_show_hp_bar] || 4) <>
        Writer.write_int8(params[:max_guild_level] || 7) <>
        Enum.reduce(members_by_level, <<>>, fn count, acc -> acc <> Writer.write_int8(count) end)
    Writer.build_packet(PacketIds.Server.guild_config(), payload)
  end

  # eChatOverHead (ID 35) — chat(String8) + charindex(Int16) + Color(Int32) +
  #   EsSpell(Bool) + x(Int8) + y(Int8) + RequiredMinDisplayTime(Int16) + MaxDisplayTime(Int16)
  def encode({:chat_over_head, params}) do
    payload =
      Writer.write_string8(params[:message] || "") <>
        Writer.write_int16(params[:char_index] || 0) <>
        Writer.write_int32(params[:color] || 0x00FFFFFF) <>
        Writer.write_bool(params[:es_spell] || false) <>
        Writer.write_int8(params[:x] || 0) <>
        Writer.write_int8(params[:y] || 0) <>
        Writer.write_int16(params[:min_display_time] || 0) <>
        Writer.write_int16(params[:max_display_time] || 0)

    Writer.build_packet(PacketIds.Server.chat_over_head(), payload)
  end

  # eErrorMsg (ID 73) — message(String8)
  def encode({:error_msg, %{message: message}}) do
    payload = Writer.write_string8(message)
    Writer.build_packet(PacketIds.Server.error_msg(), payload)
  end

  # eIntervals (ID 158) — 12 × Int32 timing intervals
  def encode({:intervals, params}) do
    payload =
      Writer.write_int32(Map.get(params, :bow, 0)) <>
      Writer.write_int32(Map.get(params, :walk, 210)) <>
      Writer.write_int32(Map.get(params, :melee, 0)) <>
      Writer.write_int32(Map.get(params, :melee_magic, 0)) <>
      Writer.write_int32(Map.get(params, :magic, 0)) <>
      Writer.write_int32(Map.get(params, :magic_melee, 0)) <>
      Writer.write_int32(Map.get(params, :melee_use, 0)) <>
      Writer.write_int32(Map.get(params, :work_extract, 0)) <>
      Writer.write_int32(Map.get(params, :work_build, 0)) <>
      Writer.write_int32(Map.get(params, :use_item, 0)) <>
      Writer.write_int32(Map.get(params, :use_click, 0)) <>
      Writer.write_int32(Map.get(params, :drop, 0))

    Writer.build_packet(PacketIds.Server.intervals(), payload)
  end

  # eChangeInventorySlot (ID 63) — slot(Int8) + obj_index(Int16) + amount(Int16) +
  #   equipped(Bool) + valor(Real32) + puede_usar(Int8) + elemental_tags(Int32) + is_bindable(Bool)
  def encode({:change_inventory_slot, params}) do
    payload =
      Writer.write_int8(params[:slot]) <>
        Writer.write_int16(params[:obj_index] || 0) <>
        Writer.write_int16(params[:amount] || 0) <>
        Writer.write_bool(params[:equipped] || false) <>
        Writer.write_real32(params[:valor] || 0.0) <>
        Writer.write_int8(params[:puede_usar] || 1) <>
        Writer.write_int32(params[:elemental_tags] || 0) <>
        Writer.write_bool(params[:is_bindable] || false)

    Writer.build_packet(PacketIds.Server.change_inventory_slot(), payload)
  end

  # eChangeSpellSlot (ID 66) — slot(Int8) + spell_id(Int16) + index(Int16) + is_bindable(Bool)
  def encode({:change_spell_slot, params}) do
    spell_id = params[:spell_id] || 0
    index = if spell_id > 0, do: spell_id, else: -1

    payload =
      Writer.write_int8(params[:slot] || 0) <>
        Writer.write_int16(spell_id) <>
        Writer.write_int16(index) <>
        Writer.write_bool(params[:is_bindable] || false)

    Writer.build_packet(PacketIds.Server.change_spell_slot(), payload)
  end

  # eObjectCreate (ID 50) — x(Int8) + y(Int8) + obj_index(Int16) + amount(Int16) + elemental_tags(Int32)
  def encode({:object_create, params}) do
    payload =
      Writer.write_int8(params[:x]) <>
        Writer.write_int8(params[:y]) <>
        Writer.write_int16(params[:obj_index] || 0) <>
        Writer.write_int16(params[:amount] || 0) <>
        Writer.write_int32(params[:elemental_tags] || 0)

    Writer.build_packet(PacketIds.Server.object_create(), payload)
  end

  # eObjectDelete (ID 52) — x(Int8) + y(Int8)
  def encode({:object_delete, %{x: x, y: y}}) do
    payload = Writer.write_int8(x) <> Writer.write_int8(y)
    Writer.build_packet(PacketIds.Server.object_delete(), payload)
  end

  # eUpdateHungerAndThirst (ID 78) — max_thirst(Int8) + min_thirst(Int8) + max_hunger(Int8) + min_hunger(Int8)
  def encode({:update_hunger_and_thirst, params}) do
    payload =
      Writer.write_int8(params[:max_thirst] || 0) <>
        Writer.write_int8(params[:min_thirst] || 0) <>
        Writer.write_int8(params[:max_hunger] || 0) <>
        Writer.write_int8(params[:min_hunger] || 0)

    Writer.build_packet(PacketIds.Server.update_hunger_and_thirst(), payload)
  end

  # eLevelUp (ID 80) — level(Int16)
  def encode({:level_up, %{level: level}}) do
    payload = Writer.write_int16(level)
    Writer.build_packet(PacketIds.Server.level_up(), payload)
  end

  # session_token (ID 200) — WS-only extension, not in VB6 protocol.
  # Sent by WsHandler after login so the web client can reconnect.
  def encode({:session_token, %{char_id: char_id, token: token}}) do
    payload = Writer.write_int32(char_id) <> Writer.write_string8(token)
    Writer.build_packet(PacketIds.Server.session_token(), payload)
  end

  # eCharSwing (ID 19) — charindex(Int16)
  def encode({:char_swing, %{char_index: char_index}}) do
    payload = Writer.write_int16(char_index)
    Writer.build_packet(PacketIds.Server.char_swing(), payload)
  end

  # eUserHittedUser (ID 34) — charindex(Int16) + target/body_part(Int8) + damage(Int16)
  def encode({:user_hitted_user, params}) do
    payload =
      Writer.write_int16(params[:char_index] || 0) <>
        Writer.write_int8(params[:target] || 1) <>
        Writer.write_int16(params[:damage] || 0)

    Writer.build_packet(PacketIds.Server.user_hitted_user(), payload)
  end

  # eUserHittedByUser (ID 33) — attacker_charindex(Int16) + target/body_part(Int8) + damage(Int16)
  def encode({:user_hitted_by_user, params}) do
    payload =
      Writer.write_int16(params[:char_index] || 0) <>
        Writer.write_int8(params[:target] || 1) <>
        Writer.write_int16(params[:damage] || 0)

    Writer.build_packet(PacketIds.Server.user_hitted_by_user(), payload)
  end

  # eNpcHitUser (ID 32) — target/body_part(Int8) + damage(Int16)
  def encode({:npc_hit_user, params}) do
    payload =
      Writer.write_int8(params[:target] || 1) <>
        Writer.write_int16(params[:damage] || 0)

    Writer.build_packet(PacketIds.Server.npc_hit_user(), payload)
  end

  # eBlockedWithShieldUser (ID 17) — no payload
  def encode({:blocked_with_shield_user, _params}) do
    Writer.build_packet(PacketIds.Server.blocked_with_shield_user(), <<>>)
  end

  # eBlockedWithShieldOther (ID 18) — charindex(Int16)
  def encode({:blocked_with_shield_other, %{char_index: char_index}}) do
    payload = Writer.write_int16(char_index)
    Writer.build_packet(PacketIds.Server.blocked_with_shield_other(), payload)
  end

  # eNpcKillUser (ID 16) — no payload
  def encode({:npc_kill_user, _params}) do
    Writer.build_packet(PacketIds.Server.npc_kill_user(), <<>>)
  end

  # eCreateFX (ID 60) — charindex(Int16) + fx(Int16) + loops(Int16) + x(Int8) + y(Int8)
  def encode({:create_fx, params}) do
    payload =
      Writer.write_int16(params[:char_index] || 0) <>
        Writer.write_int16(params[:fx] || 0) <>
        Writer.write_int16(params[:loops] || 0) <>
        Writer.write_int8(params[:x] || 0) <>
        Writer.write_int8(params[:y] || 0)

    Writer.build_packet(PacketIds.Server.create_fx(), payload)
  end

  # ePlayWave (ID 55) — wav(Int16) + x(Int8) + y(Int8) + cancel_last(Int8) + localize(Int8)
  def encode({:play_wave, params}) do
    payload =
      Writer.write_int16(params[:wav] || 0) <>
        Writer.write_int8(params[:x] || 0) <>
        Writer.write_int8(params[:y] || 0) <>
        Writer.write_int8(params[:cancel_last] || 0) <>
        Writer.write_int8(params[:localize] || 1)

    Writer.build_packet(PacketIds.Server.play_wave(), payload)
  end

  # eSafeModeOn (ID 20) — no payload
  def encode({:safe_mode_on, _params}) do
    Writer.build_packet(PacketIds.Server.safe_mode_on(), <<>>)
  end

  # eSafeModeOff (ID 21) — no payload
  def encode({:safe_mode_off, _params}) do
    Writer.build_packet(PacketIds.Server.safe_mode_off(), <<>>)
  end

  # eSendSkills (ID 87) — 24 × Int8 skill levels in VB6 order
  @skill_order [
    :magic, :stealing, :combat_tactics, :combat_weapons, :meditation,
    :short_weapons, :hiding, :survival, :trading, :combat_defense,
    :leadership, :ranged_weapons, :wrestling, :navigation, :riding,
    :resistance, :woodcutting, :fishing, :mining, :blacksmithing,
    :carpentry, :alchemy, :tailoring, :taming
  ]

  def encode({:send_skills, %{skills: skills}}) do
    payload = for skill <- @skill_order, into: <<>> do
      Writer.write_int8(Map.get(skills, skill, 0))
    end
    Writer.build_packet(PacketIds.Server.send_skills(), payload)
  end

  # eCommerceInit (ID 10) — npc_name(String8)
  def encode({:commerce_init, %{npc_name: name}}) do
    payload = Writer.write_string8(name)
    Writer.build_packet(PacketIds.Server.commerce_init(), payload)
  end

  # eChangeNPCInventorySlot (ID 77) — slot(Int8) + obj_index(Int16) + amount(Int16)
  #   + price(Real32) + elemental_tags(Int32) + puede_usar(Int8)
  def encode({:change_npc_inventory_slot, params}) do
    payload =
      Writer.write_int8(params[:slot]) <>
        Writer.write_int16(params[:obj_index] || 0) <>
        Writer.write_int16(params[:amount] || 0) <>
        Writer.write_real32(params[:price] || 0.0) <>
        Writer.write_int32(params[:elemental_tags] || 0) <>
        Writer.write_int8(params[:puede_usar] || 1)

    Writer.build_packet(PacketIds.Server.change_npc_inventory_slot(), payload)
  end

  # eCommerceEnd (ID 8) — no payload
  def encode({:commerce_end, _params}) do
    Writer.build_packet(PacketIds.Server.commerce_end(), <<>>)
  end

  # eUserCommerceInit (ID 12) — name(String8)
  # VB6 parity: the trade initiation packet includes the target player's name
  # so the client can display who you are trading with.
  def encode({:user_commerce_init, %{name: name}}) do
    payload = Writer.write_string8(name)
    Writer.build_packet(PacketIds.Server.user_commerce_init(), payload)
  end

  # Fallback for callers that don't pass a name yet (backwards-compatible).
  def encode({:user_commerce_init, _params}) do
    payload = Writer.write_string8("")
    Writer.build_packet(PacketIds.Server.user_commerce_init(), payload)
  end

  # eUserCommerceEnd (ID 13) — no payload
  def encode({:user_commerce_end, _params}) do
    Writer.build_packet(PacketIds.Server.user_commerce_end(), <<>>)
  end

  # eChangeUserTradeSlot (ID 100) — my_offer(Bool) + gold(Int32) + items[6]
  # Each item: obj_index(Int16) + name(String8) + grh_index(Int32) + amount(Int32) + elemental_tags(Int32)
  def encode({:change_user_trade_slot, params}) do
    items = params[:items] || []
    item_payload =
      Enum.reduce(0..5, <<>>, fn i, acc ->
        item = Enum.at(items, i)
        if item do
          acc <>
            Writer.write_int16(item.obj_index) <>
            Writer.write_string8(Map.get(item, :name, "")) <>
            Writer.write_int32(Map.get(item, :grh_index, 0)) <>
            Writer.write_int32(item.amount) <>
            Writer.write_int32(Map.get(item, :elemental_tags, 0))
        else
          acc <>
            Writer.write_int16(0) <>
            Writer.write_string8("") <>
            Writer.write_int32(0) <>
            Writer.write_int32(0) <>
            Writer.write_int32(0)
        end
      end)

    payload =
      Writer.write_bool(params[:my_offer] || false) <>
        Writer.write_int32(params[:gold] || 0) <>
        item_payload

    Writer.build_packet(PacketIds.Server.change_user_trade_slot(), payload)
  end

  # eNavigateToggle (ID 5) — new_state(Bool)
  def encode({:navigate_toggle, %{new_state: new_state}}) do
    payload = Writer.write_bool(new_state)
    Writer.build_packet(PacketIds.Server.navigate_toggle(), payload)
  end

  # eShowMessageBox (ID 40) — message_id(Int16) + extra(String8)
  def encode({:show_message_box, %{message_id: message_id} = params}) do
    payload =
      Writer.write_int16(message_id) <>
        Writer.write_string8(params[:extra] || "")

    Writer.build_packet(PacketIds.Server.show_message_box(), payload)
  end

  # ePlayMidi (ID 54) — midi(Int8) + loops(Int16)
  def encode({:play_midi, %{midi: midi} = params}) do
    payload =
      Writer.write_int8(midi) <>
        Writer.write_int16(params[:loops] || -1)

    Writer.build_packet(PacketIds.Server.play_midi(), payload)
  end

  # eAreaChanged (ID 57) — x(Int8) + y(Int8)
  def encode({:area_changed, %{x: x, y: y}}) do
    payload = Writer.write_int8(x) <> Writer.write_int8(y)
    Writer.build_packet(PacketIds.Server.area_changed(), payload)
  end

  # ePauseToggle (ID 58) — no payload
  def encode({:pause_toggle, _params}) do
    Writer.build_packet(PacketIds.Server.pause_toggle(), <<>>)
  end

  # eRainToggle (ID 59) — raining(Bool)
  def encode({:rain_toggle, %{raining: raining}}) do
    payload = Writer.write_bool(raining)
    Writer.build_packet(PacketIds.Server.rain_toggle(), payload)
  end

  # eSnowToggle (ID 76) — snowing(Bool)
  def encode({:snow_toggle, %{snowing: snowing}}) do
    payload = Writer.write_bool(snowing)
    Writer.build_packet(PacketIds.Server.snow_toggle(), payload)
  end

  # eFlashScreen (ID 129) — color(Int32) + duration(Int32) + ignore(Bool)
  def encode({:flash_screen, params}) do
    payload =
      Writer.write_int32(params[:color] || 0) <>
        Writer.write_int32(params[:duration] || 0) <>
        Writer.write_bool(params[:ignore] || false)

    Writer.build_packet(PacketIds.Server.flash_screen(), payload)
  end

  # ePartySafeModeOn (ID 22) — no payload
  def encode({:party_safe_mode_on, _params}) do
    Writer.build_packet(PacketIds.Server.party_safe_mode_on(), <<>>)
  end

  # ePartySafeModeOff (ID 23) — no payload
  def encode({:party_safe_mode_off, _params}) do
    Writer.build_packet(PacketIds.Server.party_safe_mode_off(), <<>>)
  end

  # eBlind (ID 74) — no payload
  def encode({:blind, _params}) do
    Writer.build_packet(PacketIds.Server.blind(), <<>>)
  end

  # eDumb (ID 75) — no payload
  def encode({:dumb, _params}) do
    Writer.build_packet(PacketIds.Server.dumb(), <<>>)
  end

  # eMiniStats (ID 79)
  # ciudadanos_matados(Int32) + criminales_matados(Int32) + faction_status(Int8)
  # + npcs_killed(Int32) + class(Int8) + penalty(Int32) + deaths(Int32)
  # + gender(Int8) + fishing_points(Int32) + race(Int8)
  def encode({:mini_stats, params}) do
    payload =
      Writer.write_int32(params[:ciudadanos_matados] || 0) <>
        Writer.write_int32(params[:criminales_matados] || 0) <>
        Writer.write_int8(params[:faction_status] || 0) <>
        Writer.write_int32(params[:npcs_killed] || 0) <>
        Writer.write_int8(params[:class] || 0) <>
        Writer.write_int32(params[:penalty] || 0) <>
        Writer.write_int32(params[:deaths] || 0) <>
        Writer.write_int8(params[:gender] || 0) <>
        Writer.write_int32(params[:fishing_points] || 0) <>
        Writer.write_int8(params[:race] || 0)

    Writer.build_packet(PacketIds.Server.mini_stats(), payload)
  end

  # eUpdateUserStats (ID 61)
  # max_hp(Int16) + min_hp(Int16) + shield(Int32) + max_mana(Int16) + min_mana(Int16)
  # + max_sta(Int16) + min_sta(Int16) + gold(Int32) + gold_cap(Int32)
  # + level(Int8) + exp_next_level(Int32) + exp(Int32) + class(Int8)
  def encode({:update_user_stats, params}) do
    payload =
      Writer.write_int16(params[:max_hp] || 0) <>
        Writer.write_int16(params[:min_hp] || 0) <>
        Writer.write_int32(params[:shield] || 0) <>
        Writer.write_int16(params[:max_mana] || 0) <>
        Writer.write_int16(params[:min_mana] || 0) <>
        Writer.write_int16(params[:max_sta] || 0) <>
        Writer.write_int16(params[:min_sta] || 0) <>
        Writer.write_int32(params[:gold] || 0) <>
        Writer.write_int32(params[:gold_cap] || 0) <>
        Writer.write_int8(params[:level] || 0) <>
        Writer.write_int32(params[:exp_next_level] || 0) <>
        Writer.write_int32(params[:exp] || 0) <>
        Writer.write_int8(params[:class] || 0)

    Writer.build_packet(PacketIds.Server.update_user_stats(), payload)
  end

  # eSendAtributes (ID 81) — str(Int8) + agi(Int8) + int(Int8) + con(Int8) + cha(Int8)
  def encode({:send_atributes, params}) do
    payload =
      Writer.write_int8(params[:str] || 0) <>
        Writer.write_int8(params[:agi] || 0) <>
        Writer.write_int8(params[:int] || 0) <>
        Writer.write_int8(params[:con] || 0) <>
        Writer.write_int8(params[:cha] || 0)

    Writer.build_packet(PacketIds.Server.send_atributes(), payload)
  end

  # eBankInit (ID 118) — bank_gold(Int32)
  # eBankInit (ID 11) — no payload (VB6: empty packet opens bank UI)
  def encode({:bank_init, _params}) do
    Writer.build_packet(PacketIds.Server.bank_init(), <<>>)
  end

  # eChangeBankSlot (ID 65) — slot(Int8) + obj_index(Int16) + elemental_tags(Int32)
  #   + amount(Int16) + valor(Int32) + puede_usar(Int8)
  def encode({:change_bank_slot, params}) do
    payload =
      Writer.write_int8(params[:slot]) <>
        Writer.write_int16(params[:obj_index] || 0) <>
        Writer.write_int32(params[:elemental_tags] || 0) <>
        Writer.write_int16(params[:amount] || 0) <>
        Writer.write_int32(params[:valor] || 0) <>
        Writer.write_int8(params[:puede_usar] || 1)

    Writer.build_packet(PacketIds.Server.change_bank_slot(), payload)
  end

  # eUpdateBankGld (ID 175) — bank_gold(Int32)
  def encode({:update_bank_gold, %{bank_gold: bank_gold}}) do
    payload = Writer.write_int32(bank_gold)
    Writer.build_packet(PacketIds.Server.update_bank_gold(), payload)
  end

  # eBankEnd (ID 9) — no payload
  def encode({:bank_end, _params}) do
    Writer.build_packet(PacketIds.Server.bank_end(), <<>>)
  end

  # eShowGMPanelForm (ID 84) — no payload, tells client to show the GM panel
  def encode({:show_gm_panel_form, _params}) do
    Writer.build_packet(PacketIds.Server.show_gm_panel_form(), <<>>)
  end

  # ---- Helpers ----

  defp encode_char_flags(params) do
    flags = 0
    flags = if params[:idle], do: Bitwise.bor(flags, 0x01), else: flags
    flags = if params[:navegando], do: Bitwise.bor(flags, 0x02), else: flags
    Writer.write_int8(flags)
  end
end
