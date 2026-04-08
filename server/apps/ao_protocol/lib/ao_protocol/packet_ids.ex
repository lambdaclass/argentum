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

    # session_token (200) — WS-only extension, not in VB6 protocol.
    # Sent by WsHandler after login so the web client can reconnect.
    # TCP handler never sends this. See encoder.ex and ws_handler.ex.
    def session_token, do: 200
  end
end
