defmodule AoProtocol.PacketIds do
  @moduledoc """
  Packet ID constants for client→server and server→client messages.

  Ported from AO20 PacketId.bas. IDs are Int16 values.
  """

  # ============================================================
  # Client → Server packet IDs (from ClientPacketID enum)
  # ============================================================
  defmodule Client do
    @moduledoc "Packet IDs sent from the client to the server."

    # Auth
    def login_existing_char, do: 73
    def login_new_char, do: 74

    # Chat
    def talk, do: 75
    def yell, do: 76
    def whisper, do: 77

    # Movement
    def walk, do: 78
    def request_position_update, do: 79

    # Combat
    def attack, do: 80
    def cast_spell, do: 94

    # Items
    def pick_up, do: 81
    def drop, do: 93
    def equip_item, do: 5
    def use_item, do: 99

    # Actions
    def left_click, do: 95
    def double_click, do: 96
    def work, do: 97
    def use_spell_macro, do: 98

    # Safety
    def safe_toggle, do: 82
    def party_safe_toggle, do: 83

    # Stats
    def request_atributes, do: 85
    def request_skills, do: 86
    def request_mini_stats, do: 87

    # Commerce (NPC)
    def commerce_start, do: 53
    def commerce_buy, do: 9
    def commerce_sell, do: 11
    def commerce_end, do: 88

    # Commerce (user-to-user, VB6: mdlCOmercioConUsuario)
    def user_commerce_offer, do: 16
    def user_commerce_end, do: 89
    def user_commerce_ok, do: 91
    def user_commerce_reject, do: 92

    # Bank
    def bank_start, do: 54
    def bank_extract_item, do: 10
    def bank_deposit, do: 12
    def bank_end, do: 90
    def bank_extract_gold, do: 70
    def bank_deposit_gold, do: 71

    # Crafting
    def craft_carpenter, do: 1
    def craft_blacksmith, do: 100
    def craft_alchemy, do: 228
    def craft_tailor, do: 230

    # Auction (VB6: eOfertaInicial=213, eOfertaDeSubasta=214, eSubastaInfo=240)
    def oferta_inicial, do: 213
    def oferta_de_subasta, do: 214
    def subasta_info, do: 240

    # Faction online queries
    def online_royal_army, do: 132
    def online_chaos_legion, do: 133

    # Council
    def council_message, do: 61

    # Forgive (VB6: ePerdonar = 68)
    def forgive, do: 68

    # Arena entry (VB6: eArenaEntry = 259)
    def arena_entry, do: 259

    # Quests (VB6: eQuest=258, eQuestListRequest=260, eQuestDetailsRequest=261, eQuestAbandon=262)
    def quest, do: 258
    def quest_accept, do: 500
    def quest_list_request, do: 260
    def quest_details_request, do: 261
    def quest_abandon, do: 262

    # Extension range: 900-999, reserved for packets with no VB6 ancestor.
    #
    # There is no "safely above VB6" region — inherited client ids already
    # include chat_color (421) and quest_accept (500) — so extensions need a
    # declared band rather than a large number. `packet_ids_test.exs` asserts
    # the band is respected and that no id is used twice.
    #
    # ping (900) — transport-independent, not WS-only: the native client needs
    # latency measurement too. Carries an opaque 8-byte token the server echoes
    # verbatim, so neither side needs to agree on a clock.
    def ping, do: 900

    @doc "Ids reserved for non-VB6 extensions."
    def extension_range, do: 900..999

    # GM chat color (VB6: eChatColor = 421, PacketId.bas:438, /CHATCOLOR)
    def chat_color, do: 421

    # GM panel request (VB6: eGMPanel = 116, PacketId.bas:351, /PANELGM)
    def gm_panel_request, do: 116

    # Duel (VB6: PacketId.bas:454-457 — eDuel=218, eAcceptDuel=219,
    # eCancelDuel=220, eQuitDuel=221). Handlers: Protocol.bas:5931-5981.
    def duel, do: 218
    def accept_duel, do: 219
    def cancel_duel, do: 220
    def quit_duel, do: 221

    # Other
    def quit, do: 39
    def rest, do: 47
    def meditate, do: 48
    def resucitate, do: 49
    def heal, do: 50
    def online, do: 38
    def change_heading, do: 6
  end

  # ============================================================
  # Server → Client packet IDs (from ServerPacketID enum)
  # ============================================================
  defmodule Server do
    @moduledoc "Packet IDs sent from the server to the client."

    # Connection
    def connected, do: 1
    def logged, do: 2
    def disconnect, do: 7

    # Navigation / mode toggles
    def navigate_toggle, do: 5
    def safe_mode_on, do: 20
    def safe_mode_off, do: 21

    # Stats
    def update_sta, do: 25
    def update_mana, do: 26
    def update_hp, do: 27
    def update_gold, do: 28
    def update_exp, do: 29

    # World
    def change_map, do: 30
    def pos_update, do: 31

    # Chat
    def chat_over_head, do: 35
    def console_msg, do: 37
    def console_faction_message, do: 38
    def guild_chat, do: 39
    def guild_list, do: 56
    def guild_news, do: 89
    def guild_leader_info, do: 94
    def guild_details, do: 95
    def show_guild_fundation_form, do: 96
    def guild_config, do: 201

    # Characters
    def character_create, do: 42
    def character_remove, do: 43
    def character_move, do: 44
    def user_index_in_server, do: 46
    def user_char_index_in_server, do: 47
    def character_change, do: 49

    # Objects
    def object_create, do: 50
    def object_delete, do: 52

    # Sound
    def play_midi, do: 54
    def play_wave, do: 55

    # Area
    def area_changed, do: 57

    # Inventory / spells
    def change_inventory_slot, do: 63
    def change_spell_slot, do: 66

    # Combat
    def npc_hit_user, do: 32
    def user_hitted_by_user, do: 33
    def user_hitted_user, do: 34
    def char_swing, do: 19
    def blocked_with_shield_user, do: 17
    def blocked_with_shield_other, do: 18

    # User stats
    def update_user_stats, do: 61
    def update_hunger_and_thirst, do: 78
    def mini_stats, do: 79
    def level_up, do: 80
    def send_atributes, do: 81
    def send_skills, do: 87

    # Error / messages
    def error_msg, do: 73
    def show_message_box, do: 40

    # Intervals / timing
    def intervals, do: 158

    # Misc
    def npc_kill_user, do: 16
    def create_fx, do: 60
    def rain_toggle, do: 59
    def pause_toggle, do: 58
    def blind, do: 74
    def dumb, do: 75
    def snow_toggle, do: 76
    def party_safe_mode_on, do: 22
    def party_safe_mode_off, do: 23

    # Status-effect clears and combat flags (VB6 PacketId.bas:83,93,106-107,118-119)
    def work_request_target, do: 62
    def rest_ok, do: 72
    def blind_no_more, do: 85
    def dumb_no_more, do: 86
    def paralize_ok, do: 97
    def stun_start, do: 98

    # Party snapshot (VB6: eDatosGrupo = 143)
    def datos_grupo, do: 143

    # Effects
    def flash_screen, do: 129

    # GM panel
    def show_gm_panel_form, do: 84

    # Commerce (NPC)
    def commerce_init, do: 10
    def commerce_end, do: 8
    def change_npc_inventory_slot, do: 77

    # Commerce (user-to-user)
    def user_commerce_init, do: 12
    def user_commerce_end, do: 13
    def change_user_trade_slot, do: 100

    # Bank (VB6: eBankInit=11, eBankEnd=9, eChangeBankSlot=65, eUpdateBankGld=175)
    def bank_init, do: 11
    def bank_end, do: 9
    def change_bank_slot, do: 65
    def update_bank_gold, do: 175

    # Crafting windows / recipe lists
    def show_blacksmith_form, do: 14
    def show_carpenter_form, do: 15
    def blacksmith_weapons, do: 68
    def blacksmith_armors, do: 69
    def blacksmith_extra_objects, do: 70
    def carpenter_objects, do: 71
    def alquimista_objects, do: 130
    def show_alchemy_form, do: 131
    def sastre_objects, do: 132
    def show_tailor_form, do: 133

    # Trainer creature list (VB6: eTrainerCreatureList = 104)
    def trainer_creature_list, do: 104

    # Spell info (VB6: eSpellInfo = 105)
    def spell_info, do: 105

    # Show forum form (VB6: eShowForumForm = 202)
    def show_forum_form, do: 202

    # session_token (200) — WS-only extension, not in VB6 protocol.
    # Sent by WsHandler after login so the web client can reconnect.
    # TCP handler never sends this. See encoder.ex and ws_handler.ex.
    def session_token, do: 200

    # Quests (VB6: eQuestDetails=153, eQuestListSend=154, eNpcQuestListSend=155)
    def quest_details, do: 153
    def quest_list_send, do: 154
    def npc_quest_list_send, do: 155

    # world_pack_signature (203) — WS-only extension carrying the expected
    # browser world-pack version/hash for this login/bootstrap.
    def world_pack_signature, do: 203

    # pong (204) — extension, not in VB6, alongside world_pack_signature (203).
    # Echoes the client's ping token unchanged; the server never interprets it.
    #
    # Server ids are a separate space from client ids and the inherited range
    # tops out well below 200, so extensions sit at 200+ here rather than in the
    # client's 900+ band.
    def pong, do: 204

    @doc "Ids reserved for non-VB6 extensions."
    def extension_range, do: 200..299
  end
end
