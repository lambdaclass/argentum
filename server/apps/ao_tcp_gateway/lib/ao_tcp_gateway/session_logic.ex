defmodule AoTcpGateway.SessionLogic do
  @moduledoc """
  Shared session lifecycle logic for TCP and WebSocket handlers.

  Functions operate on a session state map and return `{state, [packet_commands]}`
  where packet_commands are tuples that `AoProtocol.Server.Encoder` understands.
  Transport-specific concerns (sending bytes, framing) stay in each handler.

  This module acts as the public API and command router. Implementation is
  split across focused sub-modules:
  - `SessionLogin` — login, account/character creation
  - `SessionWorld` — world entry, bootstrap packets, map readiness
  - `SessionTransfer` — map transfer, /HOGAR home travel
  - `SessionPersistence` — autosave, cleanup
  - `SessionCommands.Gm` — GM administration commands
  - `SessionCommands.Guild` — guild binary + text commands
  - `SessionCommands.Chat` — talk parser, whisper, yell, group/faction/council chat, duels
  - `SessionCommands.Commerce` — NPC shops, banking, player trade, auctions
  """

  require Logger

  alias AoTcpGateway.SessionLogin
  alias AoTcpGateway.SessionWorld
  alias AoTcpGateway.SessionTransfer
  alias AoTcpGateway.SessionPersistence
  alias AoTcpGateway.SessionCommands

  # ---- Login (delegated to SessionLogin) ----

  defdelegate login_existing(state, char_id, token), to: SessionLogin
  defdelegate login_new(state, params), to: SessionLogin

  # ---- Enter world (delegated to SessionWorld) ----

  defdelegate enter_world(state, account_id, entity), to: SessionWorld

  # ---- Map transfer (delegated to SessionTransfer) ----

  defdelegate transfer(state, dest_map, dest_x, dest_y, entity), to: SessionTransfer

  # ---- /HOGAR and map transfer (delegated to SessionTransfer) ----

  defdelegate handle_hogar_check(state, entity), to: SessionTransfer
  defdelegate handle_hogar_check(state, entity, map_zone), to: SessionTransfer
  defdelegate cancel_hogar(state), to: SessionTransfer
  defdelegate maybe_cancel_hogar(state), to: SessionTransfer
  defdelegate handle_hogar_arrive(state, entity), to: SessionTransfer

  # ---- Cleanup & autosave (delegated to SessionPersistence) ----

  defdelegate cleanup(state), to: SessionPersistence
  defdelegate autosave(entity), to: SessionPersistence

  # ---- Heading conversion ----

  def int_to_heading(1), do: :north
  def int_to_heading(2), do: :east
  def int_to_heading(3), do: :south
  def int_to_heading(4), do: :west
  def int_to_heading(_), do: :south

  # ---- Public parse functions (used by tests) ----

  defdelegate parse_marriage_command(message), to: SessionCommands.Chat
  defdelegate parse_duel_command(message), to: SessionCommands.Chat

  # ===========================================================================
  # Command routing
  # ===========================================================================

  # ---- GM commands (require is_gm == true) ----

  @gm_commands [
    :go_to_char,
    :warp_me_to_target,
    :warp_char,
    :invisible,
    :silence,
    :jail,
    :kick,
    :execute,
    :ban_char,
    :unban_char,
    :revive_char,
    :summon_char,
    :kill_npc,
    :request_char_info,
    :where,
    :gm_message,
    :server_message,
    :online_gm,
    :rain_toggle,
    :online_map,
    :kick_all_chars,
    :server_open_toggle,
    :save_chars,
    :global_message,
    :kill_npc_targeted,
    :kill_npc_no_respawn,
    :kill_all_nearby_npcs,
    :create_npc,
    :create_npc_with_respawn,
    :spawn_creature,
    :spawn_list_request,
    :creatures_in_map,
    :create_item,
    :give_item,
    :request_char_stats,
    :request_char_gold,
    :request_char_inventory,
    :request_char_bank,
    :request_char_skills,
    :edit_char,
    :alter_name,
    :ban_cuenta,
    :unban_cuenta,
    :ban_temporal,
    :remove_punishment,
    :royal_army_message,
    :chaos_legion_message,
    :talk_as_npc,
    :nieve_toggle,
    :niebla_toggle,
    :change_map_pk,
    :change_map_no_magic,
    :change_map_no_invi,
    :change_map_no_resu,
    :tile_blocked_toggle,
    :set_trigger,
    :ask_trigger,
    :force_midi_all,
    :force_wave_all,
    :force_midi_map,
    :force_wave_map,
    :items_in_floor,
    :destroy_items,
    :destroy_all_area,
    :clean_world,
    :show_name,
    :set_description,
    :set_speed,
    :nick_to_ip,
    :ip_to_nick,
    :check_slot,
    :council_kick,
    :accept_royal_council,
    :accept_chaos_council,
    :royal_army_kick,
    :chaos_legion_kick,
    :sos_show_list,
    :sos_remove,
    :clean_sos
  ]

  @gm_not_authorized_msg {:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}

  # GM :online has a different handler than regular :online
  def handle_command(state, {:online, _} = cmd)
      when state.character_id != nil and state.is_gm == true do
    SessionCommands.Gm.handle_command(state, cmd)
  end

  def handle_command(state, {cmd_type, _} = cmd)
      when state.character_id != nil and state.is_gm == true and cmd_type in @gm_commands do
    SessionCommands.Gm.handle_command(state, cmd)
  end

  def handle_command(state, {cmd_type, _})
      when state.character_id != nil and cmd_type in @gm_commands do
    {state, [@gm_not_authorized_msg]}
  end

  # ---- Guild commands ----

  @guild_commands [
    :guild_create,
    :guild_leave,
    :guild_message,
    :guild_online,
    :guild_declare_war,
    :guild_kick_member,
    :guild_update_news,
    :guild_request_membership,
    :guild_accept_new_member,
    :guild_reject_new_member,
    :guild_request_details,
    :request_guild_leader_info,
    :guild_accept_peace,
    :guild_reject_peace,
    :guild_accept_alliance,
    :guild_reject_alliance,
    :guild_offer_peace,
    :guild_offer_alliance,
    :guild_alliance_details,
    :guild_peace_details,
    :guild_alliance_prop_list,
    :guild_peace_prop_list,
    :guild_request_joiner_info,
    :guild_new_website,
    :guild_member_info,
    :guild_open_elections,
    :guild_vote,
    :clan_codex_update
  ]

  def handle_command(state, {cmd_type, _} = cmd)
      when state.character_id != nil and cmd_type in @guild_commands do
    SessionCommands.Guild.handle_command(state, cmd)
  end

  # ---- Chat & communication commands ----

  @chat_commands [:talk, :yell, :whisper, :grupo_msg, :faction_message, :council_message]

  def handle_command(state, {cmd_type, _} = cmd)
      when state.character_id != nil and cmd_type in @chat_commands do
    SessionCommands.Chat.handle_command(state, cmd)
  end

  # ---- Commerce, banking, trading, auction ----

  @commerce_commands [
    :commerce_start,
    :commerce_buy,
    :commerce_sell,
    :commerce_end,
    :bank_start,
    :bank_deposit,
    :bank_extract_item,
    :bank_deposit_gold,
    :bank_extract_gold,
    :bank_end,
    :user_commerce_offer,
    :user_commerce_ok,
    :user_commerce_reject,
    :user_commerce_end,
    :oferta_inicial,
    :oferta_de_subasta,
    :subasta_info
  ]

  def handle_command(state, {cmd_type, _} = cmd)
      when state.character_id != nil and cmd_type in @commerce_commands do
    SessionCommands.Commerce.handle_command(state, cmd)
  end

  # ===========================================================================
  # Remaining gameplay commands (simple MapServer delegates)
  # ===========================================================================

  # ---- Movement ----

  def handle_command(state, {:walk, %{direction: direction}}) when state.character_id != nil do
    {state, cancel_packets} = SessionTransfer.maybe_cancel_hogar(state)
    Arena.Map.MapServer.move_character(state.map_id, state.character_id, direction)
    {state, cancel_packets}
  end

  def handle_command(state, {:walk, _}), do: {state, []}

  def handle_command(state, {:change_heading, %{heading: heading_int}})
      when state.character_id != nil do
    heading = int_to_heading(heading_int)
    Arena.Map.MapServer.change_heading(state.map_id, state.character_id, heading)
    {state, []}
  end

  def handle_command(state, {:change_heading, _}), do: {state, []}

  def handle_command(state, {:left_click, %{x: x, y: y}}) when state.character_id != nil do
    {%{state | target_x: x, target_y: y}, []}
  end

  def handle_command(state, {:request_position_update, _})
      when state.map_id != nil and state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} -> {state, [{:pos_update, %{x: entity.x, y: entity.y}}]}
      {:error, _} -> {state, []}
    end
  end

  def handle_command(state, {:request_position_update, _}), do: {state, []}

  # ---- Items ----

  def handle_command(state, {:pick_up, _}) when state.character_id != nil do
    Arena.Map.MapServer.pick_up(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:drop, %{slot: slot, amount: amount}})
      when state.character_id != nil do
    Arena.Map.MapServer.drop_item(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  def handle_command(state, {:move_item, %{from_slot: from, to_slot: to}})
      when state.character_id != nil do
    Arena.Map.MapServer.move_item(state.map_id, state.character_id, from, to)
    {state, []}
  end

  # ---- Dead guards for equip/use/attack/cast ----

  def handle_command(state, {:equip_item, _})
      when state.character_id != nil and state.is_dead == true do
    {state,
     [{:console_msg, %{message: "Estás muerto. No podés equipar objetos.", font_index: 0}}]}
  end

  def handle_command(state, {:equip_item, %{slot: slot}}) when state.character_id != nil do
    case Arena.Map.MapServer.equip_item(state.map_id, state.character_id, slot) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         [{:console_msg, %{message: "Estás muerto. No podés equipar objetos.", font_index: 0}}]}

      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:use_item, _})
      when state.character_id != nil and state.is_dead == true do
    {state, [{:console_msg, %{message: "Estás muerto. No podés usar objetos.", font_index: 0}}]}
  end

  def handle_command(state, {:use_item, %{slot: slot}}) when state.character_id != nil do
    case Arena.Map.MapServer.use_item(state.map_id, state.character_id, slot) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         [{:console_msg, %{message: "Estás muerto. No podés usar objetos.", font_index: 0}}]}

      _ ->
        {state, []}
    end
  end

  # ---- Combat ----

  def handle_command(state, {:attack, _})
      when state.character_id != nil and state.is_dead == true do
    {state, [{:console_msg, %{message: "Estás muerto. No podés atacar.", font_index: 0}}]}
  end

  def handle_command(state, {:attack, _}) when state.character_id != nil do
    {state, cancel_packets} = SessionTransfer.maybe_cancel_hogar(state)

    case Arena.Map.MapServer.attack(
           state.map_id,
           state.character_id,
           state.target_x,
           state.target_y
         ) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         cancel_packets ++
           [{:console_msg, %{message: "Estás muerto. No podés atacar.", font_index: 0}}]}

      _ ->
        {state, cancel_packets}
    end
  end

  def handle_command(state, {:cast_spell, _})
      when state.character_id != nil and state.is_dead == true do
    {state,
     [{:console_msg, %{message: "Estás muerto. No podés lanzar hechizos.", font_index: 0}}]}
  end

  def handle_command(state, {:cast_spell, %{spell_slot: slot}}) when state.character_id != nil do
    {state, cancel_packets} = SessionTransfer.maybe_cancel_hogar(state)

    case Arena.Map.MapServer.cast_spell(
           state.map_id,
           state.character_id,
           slot,
           state.target_x,
           state.target_y
         ) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         cancel_packets ++
           [{:console_msg, %{message: "Estás muerto. No podés lanzar hechizos.", font_index: 0}}]}

      _ ->
        {state, cancel_packets}
    end
  end

  # ---- Character actions ----

  def handle_command(state, {:safe_toggle, _}) when state.character_id != nil do
    Arena.Map.MapServer.safe_toggle(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:rest, _}) when state.character_id != nil do
    Arena.Map.MapServer.rest(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:meditate, _}) when state.character_id != nil do
    Arena.Map.MapServer.meditate(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:heal, _}) when state.character_id != nil do
    Arena.Map.MapServer.heal(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:resucitate, _}) when state.character_id != nil do
    Arena.Map.MapServer.resucitate(state.map_id, state.character_id)
    {%{state | is_dead: false}, []}
  end

  # ---- Stats & info ----

  def handle_command(state, {:request_atributes, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_atributes(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:request_skills, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_skills(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:request_mini_stats, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_mini_stats(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:request_stats, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_mini_stats(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:modify_skills, %{points: points}}) when state.character_id != nil do
    Arena.Map.MapServer.modify_skills(state.map_id, state.character_id, points)
    {state, []}
  end

  def handle_command(state, {:change_description, %{description: desc}})
      when state.character_id != nil do
    Arena.Map.MapServer.change_description(state.map_id, state.character_id, desc)
    {state, []}
  end

  def handle_command(state, {:spell_info, %{slot: slot}}) when state.character_id != nil do
    Arena.Map.MapServer.spell_info(state.map_id, state.character_id, slot)
    {state, []}
  end

  def handle_command(state, {:move_spell, %{upwards: upwards, slot: slot}})
      when state.character_id != nil do
    Arena.Map.MapServer.move_spell(state.map_id, state.character_id, upwards, slot)
    {state, []}
  end

  # ---- NPC interaction ----

  def handle_command(state, {:double_click, %{x: x, y: y}}) when state.character_id != nil do
    Arena.Map.MapServer.double_click(state.map_id, state.character_id, x, y)
    {state, []}
  end

  def handle_command(state, {:information, _}) when state.character_id != nil do
    Arena.Map.MapServer.double_click(
      state.map_id,
      state.character_id,
      state.target_x,
      state.target_y
    )

    {state, []}
  end

  def handle_command(state, {:train_list, _}) when state.character_id != nil do
    Arena.Map.MapServer.train_list(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:request_account_state, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_account_state(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:work, %{skill: skill_index}}) when state.character_id != nil do
    Arena.Map.MapServer.train_skill(state.map_id, state.character_id, skill_index)
    {state, []}
  end

  def handle_command(state, {:work_left_click, %{x: x, y: y, skill: skill}})
      when state.character_id != nil do
    state = %{state | target_x: x, target_y: y}
    Arena.Map.MapServer.train_skill(state.map_id, state.character_id, skill)
    {state, []}
  end

  # VB6 parity: Train (pet_index) always rejects here because pet training is
  # handled through the NPC interaction flow (train_list + double_click on trainer).
  # The standalone :train packet from the VB6 client UI is a dead path.
  def handle_command(state, {:train, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No puedes entrenar esa criatura.", font_index: 0}}]}
  end

  # ---- Crafting ----

  def handle_command(state, {:craft_blacksmith, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :blacksmithing, item)
    {state, []}
  end

  def handle_command(state, {:craft_carpenter, %{item: item, amount: amount}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :carpentry, item, max(amount, 1))
    {state, []}
  end

  def handle_command(state, {:craft_carpenter, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :carpentry, item)
    {state, []}
  end

  def handle_command(state, {:craft_alchemy, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :alchemy, item)
    {state, []}
  end

  def handle_command(state, {:craft_tailor, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :tailoring, item)
    {state, []}
  end

  # ---- Pets ----

  def handle_command(state, {:pet_stand, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_stand(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:pet_follow, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_follow(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:pet_leave, %{pet_id: pet_id}}) when state.character_id != nil do
    Arena.Map.MapServer.pet_leave(state.map_id, state.character_id, pet_id)
    {state, []}
  end

  def handle_command(state, {:pet_leave_all, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_leave_all(state.map_id, state.character_id)
    {state, []}
  end

  # ---- Party ----

  def handle_command(state, {:party_safe_toggle, _}) when state.character_id != nil do
    Arena.PartyServer.safe_toggle(state.character_id)
    {state, []}
  end

  # Genuine no-op: UseSpellMacro is a client-side convenience (VB6 hotkey macro).
  # The server receives it but needs no processing — the actual spell cast arrives
  # as a separate :cast_spell packet.
  def handle_command(state, {:use_spell_macro, _}) when state.character_id != nil do
    {state, []}
  end

  # ---- Faction ----

  def handle_command(state, {:home, _}) when state.character_id != nil do
    SessionTransfer.handle_hogar(state)
  end

  def handle_command(state, {:leave_faction, _}) when state.character_id != nil do
    Arena.Map.MapServer.leave_faction(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:online, _}) when state.character_id != nil do
    count = AoSession.OnlineDirectory.online_count()
    {state, [{:console_msg, %{message: "Jugadores en linea: #{count}", font_index: 0}}]}
  end

  def handle_command(state, {:online_royal_army, _}) when state.character_id != nil do
    members = AoSession.OnlineDirectory.list_by_faction(:royal_army)
    name_list = Enum.map_join(members, ", ", & &1.name)

    msg =
      if name_list == "",
        do: "No hay miembros de la Armada Real en linea.",
        else: "Armada Real en linea: #{name_list}"

    {state, [{:console_msg, %{message: msg, font_index: 0}}]}
  end

  def handle_command(state, {:online_chaos_legion, _}) when state.character_id != nil do
    members = AoSession.OnlineDirectory.list_by_faction(:chaos_legion)
    name_list = Enum.map_join(members, ", ", & &1.name)

    msg =
      if name_list == "",
        do: "No hay miembros de la Legion del Caos en linea.",
        else: "Legion del Caos en linea: #{name_list}"

    {state, [{:console_msg, %{message: msg, font_index: 0}}]}
  end

  # ---- Gameplay actions ----

  def handle_command(state, {:gamble, %{amount: amount}}) when state.character_id != nil do
    Arena.Map.MapServer.gamble(state.map_id, state.character_id, amount)
    {state, []}
  end

  def handle_command(state, {:forgive, %{gold_amount: gold_amount}}) when state.character_id != nil do
    Arena.Map.MapServer.forgive(state.map_id, state.character_id, gold_amount)
    {state, []}
  end

  def handle_command(state, {:arena_entry, _}) when state.character_id != nil do
    Arena.Map.MapServer.arena_entry(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:reward, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_reward(state.map_id, state.character_id)
    {state, []}
  end

  # ---- Punishments / Reporting ----

  def handle_command(state, {:punishments, %{name: name}}) when state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        if not entity.gm and entity.name != name do
          {state,
           [
             {:console_msg,
              %{message: "Servidor: Comando deshabilitado para tu cargo.", font_index: 0}}
           ]}
        else
          punishments = Map.get(entity, :punishments, [])
          text = Arena.Map.Gm.Moderation.format_punishments(punishments)
          {state, [{:console_msg, %{message: text, font_index: 0}}]}
        end

      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:denounce, %{name: name, reason: reason}})
      when state.character_id != nil do
    Arena.AuditLog.log_report(state.character_id, name, reason)
    {state, [{:console_msg, %{message: "Denuncia registrada.", font_index: 0}}]}
  end

  # ---- Gold ----

  def handle_command(state, {:donate_gold, %{amount: amount}}) when state.character_id != nil do
    if amount <= 0 do
      {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
    else
      case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
        {:ok, entity} when entity.faction == :none ->
          {state, [{:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}}]}

        {:ok, _entity} ->
          case Arena.Map.MapServer.deduct_gold(state.map_id, state.character_id, amount) do
            {:ok, new_gold} ->
              {state,
               [
                 {:update_gold, %{gold: new_gold}},
                 {:console_msg,
                  %{message: "Has donado #{amount} monedas de oro a tu faccion.", font_index: 0}}
               ]}

            {:error, _reason} ->
              {state, [{:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}}]}
          end

        _ ->
          {state, []}
      end
    end
  end

  def handle_command(state, {:transfer_gold, %{name: name, amount: amount}})
      when state.character_id != nil do
    if amount <= 0 do
      {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
    else
      case AoSession.OnlineDirectory.lookup_by_name(name) do
        {:ok, target_id, target_info} ->
          case Arena.Map.MapServer.deduct_gold(state.map_id, state.character_id, amount) do
            {:ok, new_gold} ->
              target_map = target_info.map_id
              Arena.Map.MapServer.modify_gold(target_map, target_id, amount)

              {state,
               [
                 {:update_gold, %{gold: new_gold}},
                 {:console_msg,
                  %{message: "Has transferido #{amount} oro a #{name}.", font_index: 0}}
               ]}

            {:error, _reason} ->
              {state, [{:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}}]}
          end

        :not_found ->
          {state, [{:console_msg, %{message: "Jugador no encontrado.", font_index: 0}}]}

        _ ->
          {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
      end
    end
  end

  # ---- Forum ----

  def handle_command(state, {:forum_post, %{title: title, message: body}})
      when state.character_id != nil do
    forum_id = Map.get(state, :viewing_forum_id)

    if forum_id != nil and forum_id > 0 do
      author =
        case AoSession.OnlineDirectory.lookup_by_id(state.character_id) do
          {:ok, info} -> info.name
          _ -> "Unknown"
        end

      Arena.Forum.post_message(forum_id, author, title, body)
      {state, [{:console_msg, %{message: "Mensaje publicado.", font_index: 0}}]}
    else
      {state, [{:console_msg, %{message: "El foro no esta disponible.", font_index: 0}}]}
    end
  end

  # ---- Quests ----

  def handle_command(state, {:quest, _}) when state.character_id != nil do
    Arena.Map.MapServer.quest(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:quest_list_request, _}) when state.character_id != nil do
    Arena.Map.MapServer.quest_list_request(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:quest_details_request, %{quest_slot: slot}})
      when state.character_id != nil do
    Arena.Map.MapServer.quest_details_request(state.map_id, state.character_id, slot)
    {state, []}
  end

  def handle_command(state, {:quest_accept, %{list_index: index}})
      when state.character_id != nil do
    Arena.Map.MapServer.quest_accept(state.map_id, state.character_id, index)
    {state, []}
  end

  def handle_command(state, {:quest_abandon, %{quest_slot: slot}})
      when state.character_id != nil do
    Arena.Map.MapServer.quest_abandon(state.map_id, state.character_id, slot)
    {state, []}
  end

  # ---- Server info ----

  @help_lines [
    "* Reglamento del juego: usa /REGLAMENTO para mas informacion.",
    "* Si estas muerto, dirigete a una ciudad y busca un sacerdote, el te resucitara dandole click derecho. Tambien puedes tipear /Hogar.",
    "* Para realizar una consulta a un GAME MASTER, debes utilizar el comando /GM y ellos acudiran a ti.",
    "* Para denunciar insultos de otro usuario utiliza el comando /DENUNCIAR 'nombre'.",
    "* Escribe /ONLINE para ver jugadores conectados. Usa /HOGAR para ir a tu ciudad."
  ]
  def handle_command(state, {:help, _}) when state.character_id != nil do
    msgs = Enum.map(@help_lines, fn line -> {:console_msg, %{message: line, font_index: 0}} end)
    {state, msgs}
  end

  def handle_command(state, {:request_motd, _}) when state.character_id != nil do
    motd_lines =
      Application.get_env(:ao_tcp_gateway, :motd_lines, ["Bienvenido a Argentum Online!"])

    motd_msgs =
      Enum.map(motd_lines, fn line ->
        {:console_msg, %{message: line, font_index: 0}}
      end)

    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    hours = div(uptime_ms, 3_600_000)
    minutes = div(rem(uptime_ms, 3_600_000), 60_000)

    uptime_msg =
      {:console_msg, %{message: "Uptime del servidor: #{hours}h #{minutes}m", font_index: 0}}

    {state, motd_msgs ++ [uptime_msg]}
  end

  def handle_command(state, {:uptime, _}) when state.character_id != nil do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    hours = div(uptime_ms, 3_600_000)
    minutes = div(rem(uptime_ms, 3_600_000), 60_000)
    {state, [{:console_msg, %{message: "Uptime: #{hours}h #{minutes}m", font_index: 0}}]}
  end

  # ---- Support ----

  @support_cooldown_ms 30_000

  def handle_command(state, {:role_master_request, %{request: request}})
      when state.character_id != nil do
    cond do
      request == "" ->
        {state, []}

      support_rate_limited?(state.character_id) ->
        {state,
         [
           {:console_msg,
            %{message: "Estás enviando solicitudes demasiado rápido.", font_index: 0}}
         ]}

      true ->
        player_name = AoTcpGateway.SessionHelpers.resolve_char_name(state.character_id)

        raw =
          AoProtocol.Server.Encoder.encode(
            {:console_msg, %{message: "#{player_name} PREGUNTA ROL: #{request}", font_index: 3}}
          )

        AoSession.OnlineDirectory.broadcast_to_gms({:send_raw, raw})
        {state, [{:console_msg, %{message: "Su solicitud ha sido enviada.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:question_gm, %{consulta: consulta, tipo: tipo}})
      when state.character_id != nil do
    cond do
      consulta == "" ->
        {state, []}

      support_rate_limited?(state.character_id) ->
        {state,
         [
           {:console_msg,
            %{message: "Estás enviando solicitudes demasiado rápido.", font_index: 0}}
         ]}

      true ->
        player_name = AoTcpGateway.SessionHelpers.resolve_char_name(state.character_id)

        raw =
          AoProtocol.Server.Encoder.encode(
            {:console_msg,
             %{
               message: "Se ha recibido un nuevo mensaje de soporte de #{player_name}.",
               font_index: 1
             }}
          )

        AoSession.OnlineDirectory.broadcast_to_gms({:send_raw, raw})
        Logger.info("QuestionGM from #{player_name} (#{tipo}): #{consulta}")

        {state,
         [
           {:console_msg,
            %{message: "Tu mensaje fue recibido por el equipo de soporte.", font_index: 0}}
         ]}
    end
  end

  # ---- Catch-all ----

  def handle_command(state, {command_type, _}) do
    Logger.debug("Unhandled command: #{command_type}")
    {state, []}
  end

  # ---- Private helpers ----

  defp support_rate_limited?(char_id) do
    try do
      :ets.new(:ao_support_rate_limit, [:named_table, :public, :set])
    catch
      :error, :badarg -> :ok
    end

    now = System.monotonic_time(:millisecond)

    case :ets.lookup(:ao_support_rate_limit, char_id) do
      [{^char_id, last_at}] when now - last_at < @support_cooldown_ms ->
        true

      _ ->
        :ets.insert(:ao_support_rate_limit, {char_id, now})
        false
    end
  end
end
