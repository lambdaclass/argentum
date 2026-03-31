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

  # eCharacterChange (ID 49) — charindex(Int16) + heading(Int8)
  def encode({:character_change_heading, %{char_index: char_index, heading: heading}}) do
    payload = Writer.write_int16(char_index) <> Writer.write_int8(heading)
    Writer.build_packet(PacketIds.Server.character_change(), payload)
  end

  # eCharacterRemove (ID 43) — charindex(Int16)
  def encode({:character_remove, %{char_index: char_index}}) do
    payload = Writer.write_int16(char_index)
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

  # eChangeSpellSlot (ID 66) — slot(Int8) + spell_id(Int16) + name(String8)
  def encode({:change_spell_slot, %{slot: slot, spell_id: spell_id, spell_name: spell_name}}) do
    payload =
      Writer.write_int8(slot) <>
        Writer.write_int16(spell_id) <>
        Writer.write_string8(spell_name)

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

  # eSessionToken (ID 200) — char_id(Int32) + token(String8)
  def encode({:session_token, %{char_id: char_id, token: token}}) do
    payload = Writer.write_int32(char_id) <> Writer.write_string8(token)
    Writer.build_packet(PacketIds.Server.session_token(), payload)
  end

  # eCharSwing (ID 19) — charindex(Int16)
  def encode({:char_swing, %{char_index: char_index}}) do
    payload = Writer.write_int16(char_index)
    Writer.build_packet(PacketIds.Server.char_swing(), payload)
  end

  # eUserHittedUser (ID 34) — charindex(Int16) + damage(Int32) + hp(Int32)
  def encode({:user_hitted_user, %{char_index: char_index, damage: damage, hp: hp}}) do
    payload = Writer.write_int16(char_index) <> Writer.write_int32(damage) <> Writer.write_int32(hp)
    Writer.build_packet(PacketIds.Server.user_hitted_user(), payload)
  end

  # eUserHittedByUser (ID 33) — attacker_charindex(Int16) + damage(Int32) + hp(Int32)
  def encode({:user_hitted_by_user, %{char_index: char_index, damage: damage, hp: hp}}) do
    payload = Writer.write_int16(char_index) <> Writer.write_int32(damage) <> Writer.write_int32(hp)
    Writer.build_packet(PacketIds.Server.user_hitted_by_user(), payload)
  end

  # eNpcHitUser (ID 32) — npc_charindex(Int16) + damage(Int32)
  def encode({:npc_hit_user, %{char_index: char_index, damage: damage}}) do
    payload = Writer.write_int16(char_index) <> Writer.write_int32(damage)
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

  # eCreateFX (ID 60) — charindex(Int16) + fx(Int16) + loops(Int16)
  def encode({:create_fx, %{char_index: char_index, fx: fx, loops: loops}}) do
    payload = Writer.write_int16(char_index) <> Writer.write_int16(fx) <> Writer.write_int16(loops)
    Writer.build_packet(PacketIds.Server.create_fx(), payload)
  end

  # ePlayWave (ID 55) — wav(Int8) + x(Int8) + y(Int8)
  def encode({:play_wave, %{wav: wav, x: x, y: y}}) do
    payload = Writer.write_int8(wav) <> Writer.write_int8(x) <> Writer.write_int8(y)
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

  # ---- Helpers ----

  defp encode_char_flags(params) do
    flags = 0
    flags = if params[:idle], do: Bitwise.bor(flags, 0x01), else: flags
    flags = if params[:navegando], do: Bitwise.bor(flags, 0x02), else: flags
    Writer.write_int8(flags)
  end
end
