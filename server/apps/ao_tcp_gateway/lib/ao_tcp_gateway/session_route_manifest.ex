defmodule AoTcpGateway.SessionRouteManifest do
  @moduledoc """
  Declarative routing metadata for `SessionLogic`.

  This keeps the high-churn packet/command groups and the parity-sensitive
  routes in one place so VB6 audits do not have to rediscover them by reading
  the whole router.
  """

  alias AoTcpGateway.SessionCommands
  alias AoTcpGateway.SessionLogic

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
      :clean_sos,
      :chat_color,
      :gm_panel_request
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
    duel: [:duel, :accept_duel, :cancel_duel, :quit_duel],
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

  # Dispatch target aliases
  @session SessionLogic
  @map {Arena.Map.MapServer, :cast}
  @gm {SessionCommands.Gm, :handle_command}
  @guild {SessionCommands.Guild, :handle_command}
  @chat {SessionCommands.Chat, :handle_command}
  @commerce {SessionCommands.Commerce, :handle_command}
  @duel {SessionCommands.Duel, :handle_command}

  @routes %{
    # ── Movement ───────────────────────────────────────────────────────
    walk: %{group: :movement, dispatch: @map, vb6_ref: "Protocol.bas:1635:HandleWalk", parity_status: :exact},
    change_heading: %{group: :movement, dispatch: @map, vb6_ref: "Protocol.bas:3060:HandleChange_Heading", parity_status: :exact},
    left_click: %{group: :movement, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:2213:HandleLeftClick", parity_status: :exact},
    request_position_update: %{group: :movement, dispatch: @map, vb6_ref: "Protocol.bas:1755:HandleRequestPositionUpdate", parity_status: :exact},

    # ── Items ──────────────────────────────────────────────────────────
    pick_up: %{group: :items, dispatch: @map, vb6_ref: "Protocol.bas:1819:HandlePickUp", parity_status: :exact},
    drop: %{group: :items, dispatch: @map, vb6_ref: "Protocol.bas:2057:HandleDrop", parity_status: :exact},
    move_item: %{group: :items, dispatch: @map, vb6_ref: "Protocol.bas:6057:HandleMoveItem", parity_status: :exact},
    equip_item: %{group: :items, dispatch: @map, vb6_ref: "Protocol.bas:2999:HandleEquipItem", parity_status: :exact},
    use_item: %{group: :items, dispatch: @map, vb6_ref: "Protocol.bas:2340:HandleUseItem", parity_status: :exact},

    # ── Combat ─────────────────────────────────────────────────────────
    attack: %{group: :combat, dispatch: @map, vb6_ref: "Protocol.bas:1768:HandleAttack", parity_status: :exact},
    cast_spell: %{group: :combat, dispatch: @map, vb6_ref: "Protocol.bas:2195:HandleCastSpell", parity_status: :exact},

    # ── Character actions ──────────────────────────────────────────────
    safe_toggle: %{group: :character, dispatch: @map, vb6_ref: "Protocol.bas:1845:HandleSafeToggle", parity_status: :exact},
    rest: %{group: :character, dispatch: @map, vb6_ref: "Protocol.bas:rest via healing.ex", parity_status: :exact},
    meditate: %{group: :character, dispatch: @map, vb6_ref: "Protocol.bas:meditate via healing.ex", parity_status: :exact},
    heal: %{group: :character, dispatch: @map, vb6_ref: "Protocol.bas:heal via healing.ex", parity_status: :exact},
    resucitate: %{group: :character, dispatch: @map, vb6_ref: "Protocol.bas:resucitate via healing.ex", parity_status: :exact},
    use_spell_macro: %{group: :character, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:2324:HandleUseSpellMacro", parity_status: :exact},

    # ── Stats & info ───────────────────────────────────────────────────
    request_atributes: %{group: :stats, dispatch: @map, vb6_ref: "Protocol.bas:1923:HandleRequestAtributes", parity_status: :exact},
    request_skills: %{group: :stats, dispatch: @map, vb6_ref: "Protocol.bas:1935:HandleRequestSkills", parity_status: :exact},
    request_mini_stats: %{group: :stats, dispatch: @map, vb6_ref: "Protocol.bas:1947:HandleRequestMiniStats", parity_status: :exact},
    request_stats: %{group: :stats, dispatch: @map, vb6_ref: "Protocol_GmCommands.bas:66:HandleRequestStats", parity_status: :exact},
    modify_skills: %{group: :stats, dispatch: @map, vb6_ref: "Protocol.bas:3091:HandleModifySkills", parity_status: :exact},
    change_description: %{group: :stats, dispatch: @map, vb6_ref: "Protocol_GmCommands.bas:2275:HandleSetCharDescription", parity_status: :exact},
    spell_info: %{group: :stats, dispatch: @map, vb6_ref: "Protocol.bas:2969:HandleSpellInfo", parity_status: :exact},
    move_spell: %{group: :stats, dispatch: @map, vb6_ref: "Protocol.bas:3355:HandleMoveSpell", parity_status: :exact},

    # ── NPC interaction ────────────────────────────────────────────────
    double_click: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:2237:HandleDoubleClick", parity_status: :exact},
    information: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:HandleInformation", parity_status: :exact},
    train_list: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:train list via npc_interaction.ex", parity_status: :exact},
    request_account_state: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:4006:HandleRequestAccountState", parity_status: :exact},
    work: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:2251:HandleWork", parity_status: :exact},
    work_left_click: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:2462:HandleWorkLeftClick", parity_status: :exact},
    train: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:3141:HandleTrain", parity_status: :exact},

    # ── Crafting ───────────────────────────────────────────────────────
    craft_blacksmith: %{group: :crafting, dispatch: @map, vb6_ref: "Protocol.bas:2398:HandleCraftBlacksmith", parity_status: :exact},
    craft_carpenter: %{group: :crafting, dispatch: @map, vb6_ref: "Protocol.bas:2414:HandleCraftCarpenter", parity_status: :exact},
    craft_alchemy: %{group: :crafting, dispatch: @map, vb6_ref: "Protocol.bas:2436:HandleCraftAlquimia", parity_status: :exact},
    craft_tailor: %{group: :crafting, dispatch: @map, vb6_ref: "Protocol.bas:2447:HandleCraftSastre", parity_status: :exact},

    # ── Pets ───────────────────────────────────────────────────────────
    pet_stand: %{group: :pets, dispatch: @map, vb6_ref: "Protocol.bas:4052:HandlePetStand", parity_status: :exact},
    pet_follow: %{group: :pets, dispatch: @map, vb6_ref: "Protocol.bas:4087:HandlePetFollow", parity_status: :exact},
    pet_leave: %{group: :pets, dispatch: @map, vb6_ref: "Protocol.bas:pet leave via pets.ex", parity_status: :exact},
    pet_leave_all: %{group: :pets, dispatch: @map, vb6_ref: "Protocol.bas:7662:HandlePetLeaveAll", parity_status: :exact},
    pet_follow_all: %{group: :pets, dispatch: @map, vb6_ref: "Protocol.bas:4117:HandlePetFollowAll", parity_status: :exact},

    # ── Party ──────────────────────────────────────────────────────────
    party_safe_toggle: %{group: :party, dispatch: {Arena.PartyServer, :safe_toggle}, vb6_ref: "Protocol.bas:1881:HandlePartyToggle", parity_status: :exact},

    # ── Faction ────────────────────────────────────────────────────────
    home: %{group: :faction, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:7414:HandleHome", parity_status: :simplified},
    leave_faction: %{group: :faction, dispatch: @map, vb6_ref: "Protocol.bas:leave faction via faction.ex", parity_status: :exact},
    online: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:31:HandleOnline", parity_status: :exact},
    online_royal_army: %{group: :faction, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:5158:HandleRoyalArmyMessage", parity_status: :exact},
    online_chaos_legion: %{group: :faction, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:5196:HandleChaosLegionMessage", parity_status: :exact},

    # ── Duels (VB6: Protocol.bas:5931-5981 HandleDuel/HandleAcceptDuel/HandleCancelDuel/HandleQuitDuel) ──
    duel: %{group: :duel, dispatch: @duel, vb6_ref: "Protocol.bas:5931:HandleDuel", parity_status: :exact},
    accept_duel: %{group: :duel, dispatch: @duel, vb6_ref: "Protocol.bas:5952:HandleAcceptDuel", parity_status: :exact},
    cancel_duel: %{group: :duel, dispatch: @duel, vb6_ref: "Protocol.bas:5964:HandleCancelDuel", parity_status: :exact},
    quit_duel: %{group: :duel, dispatch: @duel, vb6_ref: "Protocol.bas:5975:HandleQuitDuel", parity_status: :exact},

    # ── Gameplay actions ───────────────────────────────────────────────
    gamble: %{group: :npc, dispatch: @map, vb6_ref: "Protocol_GmCommands.bas:181:HandleGamble", parity_status: :exact},
    forgive: %{group: :npc, dispatch: @map, vb6_ref: "Protocol_GmCommands.bas:1681:HandleForgive", parity_status: :exact},
    arena_entry: %{group: :npc, dispatch: @map, vb6_ref: "Protocol.bas:5739:HandleParticipar", parity_status: :exact},
    reward: %{group: :character, dispatch: @map, vb6_ref: "Protocol.bas:reward via social.ex", parity_status: :exact},

    # ── Punishments / Reporting ────────────────────────────────────────
    punishments: %{group: :support, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:129:HandlePunishments", parity_status: :simplified},
    denounce: %{group: :support, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:280:HandleDenounce", parity_status: :simplified},

    # ── Gold ───────────────────────────────────────────────────────────
    donate_gold: %{group: :faction, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:5563:HandleDonateGold", parity_status: :exact},
    transfer_gold: %{group: :commerce, dispatch: @map, vb6_ref: "Protocol.bas:5983:HandleTransFerGold", parity_status: :exact},

    # ── Forum ──────────────────────────────────────────────────────────
    forum_post: %{group: :social, dispatch: {@session, :handle_command}, vb6_ref: "Protocol.bas:3306:HandleForumPost", parity_status: :simplified},

    # ── Quests ─────────────────────────────────────────────────────────
    quest: %{group: :quest, dispatch: @map, vb6_ref: "Protocol.bas:7010:HandleQuest", parity_status: :exact},
    quest_list_request: %{group: :quest, dispatch: @map, vb6_ref: "Protocol.bas:7163:HandleQuestListRequest", parity_status: :exact},
    quest_details_request: %{group: :quest, dispatch: @map, vb6_ref: "Protocol.bas:7095:HandleQuestDetailsRequest", parity_status: :exact},
    quest_accept: %{group: :quest, dispatch: @map, vb6_ref: "Protocol.bas:7033:HandleQuestAccept", parity_status: :exact},
    quest_abandon: %{group: :quest, dispatch: @map, vb6_ref: "Protocol.bas:7113:HandleQuestAbandon", parity_status: :exact},

    # ── Server info ────────────────────────────────────────────────────
    help: %{group: :info, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:56:HandleHelp", parity_status: :simplified},
    request_motd: %{group: :info, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:76:HandleRequestMOTD", parity_status: :exact},
    uptime: %{group: :info, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:86:HandleUpTime", parity_status: :exact},
    ping: %{group: :info, dispatch: {@session, :handle_command}, vb6_ref: "none:extension:Ping", parity_status: :intentional_divergence},

    # ── Support ────────────────────────────────────────────────────────
    question_gm: %{group: :support, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:3342:HandleQuestionGM", parity_status: :simplified},
    role_master_request: %{group: :support, dispatch: {@session, :handle_command}, vb6_ref: "Protocol_GmCommands.bas:112:HandleRoleMasterRequest", parity_status: :simplified},

    # ── Chat ───────────────────────────────────────────────────────────
    talk: %{group: :chat, dispatch: @chat, vb6_ref: "Protocol.bas:1469:HandleTalk", parity_status: :exact},
    yell: %{group: :chat, dispatch: @chat, vb6_ref: "Protocol.bas:1517:HandleYell", parity_status: :exact},
    whisper: %{group: :chat, dispatch: @chat, vb6_ref: "Protocol.bas:1583:HandleWhisper", parity_status: :exact},
    grupo_msg: %{group: :chat, dispatch: @chat, vb6_ref: "Protocol.bas:grupo message flow", parity_status: :exact},
    faction_message: %{group: :chat, dispatch: @chat, vb6_ref: "Protocol.bas:5211:HandleFactionMessage", parity_status: :exact},
    council_message: %{group: :chat, dispatch: @chat, vb6_ref: "Protocol.bas:council message flow", parity_status: :exact},

    # ── Commerce ───────────────────────────────────────────────────────
    commerce_start: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:commerce start flow", parity_status: :exact},
    commerce_buy: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:3171:HandleCommerceBuy", parity_status: :exact},
    commerce_sell: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:3239:HandleCommerceSell", parity_status: :exact},
    commerce_end: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:1959:HandleCommerceEnd", parity_status: :exact},
    bank_start: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:bank start flow", parity_status: :exact},
    bank_deposit: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:3270:HandleBankDeposit", parity_status: :exact},
    bank_extract_item: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:3209:HandleBankExtractItem", parity_status: :exact},
    bank_deposit_gold: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:bank deposit gold flow", parity_status: :exact},
    bank_extract_gold: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:bank extract gold flow", parity_status: :exact},
    bank_end: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:2000:HandleBankEnd", parity_status: :exact},
    user_commerce_offer: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:3389:HandleUserCommerceOffer", parity_status: :exact},
    user_commerce_ok: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:2018:HandleUserCommerceOk", parity_status: :exact},
    user_commerce_reject: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:2031:HandleUserCommerceReject", parity_status: :exact},
    user_commerce_end: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:1978:HandleUserCommerceEnd", parity_status: :exact},
    oferta_inicial: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:5821:HandleOfertaInicial", parity_status: :exact},
    oferta_de_subasta: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:5879:HandleOfertaDeSubasta", parity_status: :exact},
    subasta_info: %{group: :commerce, dispatch: @commerce, vb6_ref: "Protocol.bas:6803:HandleSubastaInfo", parity_status: :exact},

    # ── Guild ──────────────────────────────────────────────────────────
    guild_create: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:2936:HandleCreateNewGuild", parity_status: :intentional_divergence},
    guild_leave: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3982:HandleGuildLeave", parity_status: :intentional_divergence},
    guild_message: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:guild message flow", parity_status: :intentional_divergence},
    guild_online: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:guild online flow", parity_status: :intentional_divergence},
    guild_declare_war: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3731:HandleGuildDeclareWar", parity_status: :intentional_divergence},
    guild_kick_member: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3836:HandleGuildKickMember", parity_status: :intentional_divergence},
    guild_update_news: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3869:HandleGuildUpdateNews", parity_status: :intentional_divergence},
    guild_request_membership: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3909:HandleGuildRequestMembership", parity_status: :intentional_divergence},
    guild_accept_new_member: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3772:HandleGuildAcceptNewMember", parity_status: :intentional_divergence},
    guild_reject_new_member: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3806:HandleGuildRejectNewMember", parity_status: :intentional_divergence},
    guild_request_details: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3933:HandleGuildRequestDetails", parity_status: :intentional_divergence},
    request_guild_leader_info: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:1911:HandleRequestGuildLeaderInfo", parity_status: :intentional_divergence},
    guild_accept_peace: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3497:HandleGuildAcceptPeace", parity_status: :intentional_divergence},
    guild_reject_peace: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3547:HandleGuildRejectPeace", parity_status: :intentional_divergence},
    guild_accept_alliance: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3572:HandleGuildAcceptAlliance", parity_status: :intentional_divergence},
    guild_reject_alliance: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3522:HandleGuildRejectAlliance", parity_status: :intentional_divergence},
    guild_offer_peace: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3597:HandleGuildOfferPeace", parity_status: :intentional_divergence},
    guild_offer_alliance: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3617:HandleGuildOfferAlliance", parity_status: :intentional_divergence},
    guild_alliance_details: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3638:HandleGuildAllianceDetails", parity_status: :intentional_divergence},
    guild_peace_details: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3663:HandleGuildPeaceDetails", parity_status: :intentional_divergence},
    guild_alliance_prop_list: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3705:HandleGuildAlliancePropList", parity_status: :intentional_divergence},
    guild_peace_prop_list: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3718:HandleGuildPeacePropList", parity_status: :intentional_divergence},
    guild_request_joiner_info: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3682:HandleGuildRequestJoinerInfo", parity_status: :intentional_divergence},
    guild_new_website: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3760:HandleGuildNewWebsite", parity_status: :intentional_divergence},
    guild_member_info: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3881:HandleGuildMemberInfo", parity_status: :intentional_divergence},
    guild_open_elections: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3893:HandleGuildOpenElections", parity_status: :intentional_divergence},
    guild_vote: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:guild vote flow", parity_status: :intentional_divergence},
    clan_codex_update: %{group: :guild, dispatch: @guild, vb6_ref: "Protocol.bas:3373:HandleClanCodexUpdate", parity_status: :intentional_divergence},

    # ── GM commands ────────────────────────────────────────────────────
    go_to_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:706:HandleGoToChar", parity_status: :simplified},
    warp_me_to_target: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:545:HandleWarpMeToTarget", parity_status: :exact},
    warp_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:558:HandleWarpChar", parity_status: :exact},
    invisible: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:752:HandleInvisible", parity_status: :exact},
    silence: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:621:HandleSilence", parity_status: :exact},
    jail: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:863:HandleJail", parity_status: :exact},
    kick: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1748:HandleKick", parity_status: :exact},
    execute: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1782:HandleExecute", parity_status: :exact},
    ban_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1811:HandleBanChar", parity_status: :exact},
    unban_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1831:HandleUnbanChar", parity_status: :exact},
    revive_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1569:HandleReviveChar", parity_status: :exact},
    summon_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1882:HandleSummonChar", parity_status: :exact},
    kill_npc: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:920:HandleKillNPC", parity_status: :exact},
    request_char_info: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1411:HandleRequestCharInfo", parity_status: :exact},
    where: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:421:HandleWhere", parity_status: :exact},
    gm_message: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:323:HandleGMMessage", parity_status: :exact},
    server_message: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2040:HandleServerMessage", parity_status: :exact},
    online_gm: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1622:HandleOnlineGM", parity_status: :exact},
    rain_toggle: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2250:HandleRainToggle", parity_status: :exact},
    online_map: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1654:HandleOnlineMap", parity_status: :exact},
    kick_all_chars: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3162:HandleKickAllChars", parity_status: :exact},
    server_open_toggle: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5720:HandleServerOpenToUsersToggle", parity_status: :exact},
    save_chars: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3119:HandleSaveChars", parity_status: :exact},
    global_message: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3238:HandleGlobalMessage", parity_status: :exact},
    kill_npc_targeted: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:920:HandleKillNPC (targeted)", parity_status: :exact},
    kill_npc_no_respawn: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2688:HandleKillNPCNoRespawn", parity_status: :exact},
    kill_all_nearby_npcs: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2707:HandleKillAllNearbyNPCs", parity_status: :exact},
    create_npc: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2789:HandleCreateNPC", parity_status: :exact},
    create_npc_with_respawn: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2811:HandleCreateNPCWithRespawn", parity_status: :exact},
    spawn_creature: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1981:HandleSpawnCreature", parity_status: :exact},
    spawn_list_request: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1960:HandleSpawnListRequest", parity_status: :exact},
    creatures_in_map: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:450:HandleCreaturesInMap", parity_status: :exact},
    create_item: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2515:HandleCreateItem", parity_status: :exact},
    give_item: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3294:HandleGiveItem", parity_status: :exact},
    request_char_stats: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1439:HandleRequestCharStats", parity_status: :exact},
    request_char_gold: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1463:HandleRequestCharGold", parity_status: :exact},
    request_char_inventory: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1488:HandleRequestCharInventory", parity_status: :exact},
    request_char_bank: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1511:HandleRequestCharBank", parity_status: :exact},
    request_char_skills: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1537:HandleRequestCharSkills", parity_status: :exact},
    edit_char: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:1008:HandleEditChar", parity_status: :exact},
    alter_name: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2833:HandleAlterName", parity_status: :exact},
    ban_cuenta: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3517:HandleBanCuenta", parity_status: :exact},
    unban_cuenta: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3537:HandleUnBanCuenta", parity_status: :exact},
    ban_temporal: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3665:HandleBanTemporal", parity_status: :exact},
    remove_punishment: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2631:HandleRemovePunishment", parity_status: :exact},
    royal_army_message: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5158:HandleRoyalArmyMessage (GM variant)", parity_status: :exact},
    chaos_legion_message: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5196:HandleChaosLegionMessage (GM variant)", parity_status: :exact},
    talk_as_npc: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2354:HandleTalkAsNPC", parity_status: :exact},
    nieve_toggle: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3463:HandleNieveToggle", parity_status: :exact},
    niebla_toggle: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3481:HandleNieblaToggle", parity_status: :exact},
    change_map_pk: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2901:HandleChangeMapInfoPK", parity_status: :exact},
    change_map_no_magic: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3083:HandleChangeMapSetting (no_magic)", parity_status: :exact},
    change_map_no_invi: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3083:HandleChangeMapSetting (no_invi)", parity_status: :exact},
    change_map_no_resu: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3083:HandleChangeMapSetting (no_resu)", parity_status: :exact},
    tile_blocked_toggle: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2666:HandleTile_BlockedToggle", parity_status: :exact},
    set_trigger: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2480:HandleSetTrigger", parity_status: :exact},
    ask_trigger: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2500:HandleAskTrigger", parity_status: :exact},
    force_midi_all: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2594:HandleForceMIDIAll", parity_status: :exact},
    force_wave_all: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2613:HandleForceWAVEAll", parity_status: :exact},
    force_midi_map: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:force MIDI map flow", parity_status: :exact},
    force_wave_map: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2325:HandleForceWAVEToMap", parity_status: :exact},
    items_in_floor: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2405:HandleItemsInTheFloor", parity_status: :exact},
    destroy_items: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2576:HandleDestroyItems", parity_status: :exact},
    destroy_all_area: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2376:HandleDestroyAllItemsInArea", parity_status: :exact},
    clean_world: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2023:HandleCleanWorld", parity_status: :exact},
    show_name: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:340:HandleShowName", parity_status: :exact},
    set_description: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2275:HandleSetCharDescription", parity_status: :exact},
    set_speed: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3223:HandleSetSpeed", parity_status: :exact},
    nick_to_ip: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2061:HandleNickToIP", parity_status: :exact},
    ip_to_nick: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:2111:HandleIPToNick", parity_status: :exact},
    check_slot: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3187:HandleCheckSlot", parity_status: :exact},
    council_kick: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5345:HandleCouncilKick", parity_status: :exact},
    accept_royal_council: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5272:HandleAcceptRoyalCouncilMember", parity_status: :exact},
    accept_chaos_council: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5309:HandleAcceptChaosCouncilMember", parity_status: :exact},
    royal_army_kick: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5491:HandleRoyalArmyKick", parity_status: :exact},
    chaos_legion_kick: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5438:HandleChaosLegionKick", parity_status: :exact},
    sos_show_list: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:681:HandleSOSShowList", parity_status: :exact},
    sos_remove: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:693:HandleSOSRemove", parity_status: :exact},
    clean_sos: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:3136:HandleCleanSOS", parity_status: :exact},
    chat_color: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol.bas:5548:HandleChatColor", parity_status: :exact},
    gm_panel_request: %{group: :gm, dispatch: @gm, vb6_ref: "Protocol_GmCommands.bas:764:HandleGMPanel", parity_status: :exact}
  }

  def groups, do: @groups

  def group(name), do: Map.fetch!(@groups, name)

  def route(cmd_type), do: Map.get(@routes, cmd_type)

  def routes, do: @routes

  def parity_statuses, do: @parity_statuses
end
