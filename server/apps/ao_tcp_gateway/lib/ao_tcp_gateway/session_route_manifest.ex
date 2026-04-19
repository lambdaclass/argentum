defmodule AoTcpGateway.SessionRouteManifest do
  @moduledoc """
  Declarative routing metadata for `SessionLogic`.

  This keeps the high-churn packet/command groups and the parity-sensitive
  routes in one place so VB6 audits do not have to rediscover them by reading
  the whole router.
  """

  alias AoTcpGateway.SessionCommands

  @parity_statuses [:exact, :simplified, :intentional_divergence, :unimplemented]

  @groups %{
    gm: [
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
    ],
    guild: [
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
    ],
    chat: [:talk, :yell, :whisper, :grupo_msg, :faction_message, :council_message],
    commerce: [
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
  }

  @routes %{
    online: %{
      group: :gm,
      dispatch: {SessionCommands.Gm, :handle_command},
      vb6_ref: "Protocol_GmCommands.bas:/ONLINE",
      parity_status: :exact
    },
    information: %{
      group: :map,
      dispatch: {Arena.Map.MapServer, :information},
      vb6_ref: "Protocol.bas:HandleInformation",
      parity_status: :exact
    },
    quest: %{
      group: :map,
      dispatch: {Arena.Map.MapServer, :quest},
      vb6_ref: "Protocol.bas:HandleQuest",
      parity_status: :exact
    },
    quest_list_request: %{
      group: :map,
      dispatch: {Arena.Map.MapServer, :quest_list_request},
      vb6_ref: "Protocol.bas:quest window list flow",
      parity_status: :exact
    },
    quest_details_request: %{
      group: :map,
      dispatch: {Arena.Map.MapServer, :quest_details_request},
      vb6_ref: "Protocol.bas:quest window details flow",
      parity_status: :exact
    },
    quest_accept: %{
      group: :map,
      dispatch: {Arena.Map.MapServer, :quest_accept},
      vb6_ref: "Protocol.bas:quest accept flow",
      parity_status: :exact
    },
    quest_abandon: %{
      group: :map,
      dispatch: {Arena.Map.MapServer, :quest_abandon},
      vb6_ref: "Protocol.bas:quest abandon flow",
      parity_status: :exact
    },
    question_gm: %{
      group: :support,
      dispatch: {AoTcpGateway.SessionLogic, :handle_command},
      vb6_ref: "Protocol_GmCommands.bas:HandleQuestionGM",
      parity_status: :simplified
    },
    role_master_request: %{
      group: :support,
      dispatch: {AoTcpGateway.SessionLogic, :handle_command},
      vb6_ref: "Protocol_GmCommands.bas:HandleRoleMasterRequest",
      parity_status: :simplified
    },
    train: %{
      group: :map,
      dispatch: {AoTcpGateway.SessionLogic, :handle_command},
      vb6_ref: "Protocol.bas:HandleTrain",
      parity_status: :unimplemented
    },
    guild_accept_peace: %{
      group: :guild,
      dispatch: {SessionCommands.Guild, :handle_command},
      vb6_ref: "Protocol.bas:guild peace accept flow",
      parity_status: :intentional_divergence
    },
    guild_reject_peace: %{
      group: :guild,
      dispatch: {SessionCommands.Guild, :handle_command},
      vb6_ref: "Protocol.bas:guild peace reject flow",
      parity_status: :intentional_divergence
    },
    guild_accept_alliance: %{
      group: :guild,
      dispatch: {SessionCommands.Guild, :handle_command},
      vb6_ref: "Protocol.bas:guild alliance accept flow",
      parity_status: :intentional_divergence
    },
    guild_reject_alliance: %{
      group: :guild,
      dispatch: {SessionCommands.Guild, :handle_command},
      vb6_ref: "Protocol.bas:guild alliance reject flow",
      parity_status: :intentional_divergence
    },
    guild_open_elections: %{
      group: :guild,
      dispatch: {SessionCommands.Guild, :handle_command},
      vb6_ref: "Protocol.bas:guild elections",
      parity_status: :intentional_divergence
    },
    guild_vote: %{
      group: :guild,
      dispatch: {SessionCommands.Guild, :handle_command},
      vb6_ref: "Protocol.bas:guild vote",
      parity_status: :intentional_divergence
    }
  }

  def groups, do: @groups

  def group(name), do: Map.fetch!(@groups, name)

  def route(cmd_type), do: Map.get(@routes, cmd_type)

  def routes, do: @routes

  def parity_statuses, do: @parity_statuses
end
