defmodule AoProtocol.GoldenProtocolTest do
  @moduledoc """
  Golden byte tests that verify our encoder/decoder produce the exact same
  binary output as the VB6 AO20 server (Protocol_Writes.bas / Protocol.bas).

  Each test manually constructs the expected binary by following the exact
  sequence of Writer calls from the VB6 source, then asserts our Elixir
  encoder produces identical bytes.
  """

  use ExUnit.Case, async: true

  alias AoProtocol.Server.Encoder
  alias AoProtocol.Client.Decoder

  # ============================================================
  # Server → Client encoder golden tests
  # ============================================================

  describe "elogged (ID 2) golden bytes" do
    # VB6: WriteInt16(2) + WriteBool(newUser)
    test "matches VB6 WriteLoggedMessage with newUser=false" do
      result = Encoder.encode({:logged, %{new_user: false}})

      expected =
        <<2::little-signed-16>> <>  # ServerPacketID.elogged = 2
        <<0>>                        # WriteBool(False)

      assert result == expected
    end

    test "matches VB6 WriteLoggedMessage with newUser=true" do
      result = Encoder.encode({:logged, %{new_user: true}})

      expected =
        <<2::little-signed-16>> <>
        <<1>>

      assert result == expected
    end
  end

  describe "eChangeMap (ID 30) golden bytes" do
    # VB6: WriteInt16(30) + WriteInt16(Map) + WriteInt16(MapResource)
    test "matches VB6 WriteChangeMap" do
      result = Encoder.encode({:change_map, %{map_id: 1, version: 42}})

      expected =
        <<30::little-signed-16>> <>  # ServerPacketID.eChangeMap = 30
        <<1::little-signed-16>> <>   # Map = 1
        <<42::little-signed-16>>     # MapResource = 42

      assert result == expected
    end
  end

  describe "ePosUpdate (ID 31) golden bytes" do
    # VB6: WriteInt16(31) + WriteInt8(x) + WriteInt8(y)
    test "matches VB6 WritePosUpdate" do
      result = Encoder.encode({:pos_update, %{x: 50, y: 75}})

      expected =
        <<31::little-signed-16>> <>  # ServerPacketID.ePosUpdate = 31
        <<50>> <>                     # x
        <<75>>                        # y

      assert result == expected
    end
  end

  describe "eUpdateSta (ID 25) golden bytes" do
    # VB6: WriteInt16(25) + WriteInt16(MinSta)
    test "matches VB6 WriteUpdateSta" do
      result = Encoder.encode({:update_stamina, %{min_sta: 85}})

      expected =
        <<25::little-signed-16>> <>  # ServerPacketID.eUpdateSta = 25
        <<85::little-signed-16>>     # MinSta

      assert result == expected
    end
  end

  describe "eUpdateMana (ID 26) golden bytes" do
    # VB6: WriteInt16(26) + WriteInt16(MinMAN)
    test "matches VB6 WriteUpdateMana" do
      result = Encoder.encode({:update_mana, %{min_mana: 200}})

      expected =
        <<26::little-signed-16>> <>   # ServerPacketID.eUpdateMana = 26
        <<200::little-signed-16>>     # MinMAN

      assert result == expected
    end
  end

  describe "eUpdateHP (ID 27) golden bytes" do
    # VB6: WriteInt16(27) + WriteInt16(MinHp) + WriteInt32(shield)
    test "matches VB6 WriteUpdateHP" do
      result = Encoder.encode({:update_hp, %{min_hp: 150, shield: 10}})

      expected =
        <<27::little-signed-16>> <>   # ServerPacketID.eUpdateHP = 27
        <<150::little-signed-16>> <>  # MinHp
        <<10::little-signed-32>>      # shield

      assert result == expected
    end

    test "shield defaults to 0" do
      result = Encoder.encode({:update_hp, %{min_hp: 100}})

      expected =
        <<27::little-signed-16>> <>
        <<100::little-signed-16>> <>
        <<0::little-signed-32>>

      assert result == expected
    end
  end

  describe "eUpdateGold (ID 28) golden bytes" do
    # VB6: WriteInt16(28) + WriteInt32(GLD) + WriteInt32(OroPorNivelBilletera)
    test "matches VB6 WriteUpdateGold" do
      result = Encoder.encode({:update_gold, %{gold: 5000}})

      expected =
        <<28::little-signed-16>> <>    # ServerPacketID.eUpdateGold = 28
        <<5000::little-signed-32>> <>  # GLD
        <<0::little-signed-32>>        # OroPorNivelBilletera (we default to 0)

      assert result == expected
    end
  end

  describe "eConsoleMsg (ID 37) golden bytes" do
    # VB6: WriteInt16(37) + WriteString8(chat) + WriteInt8(FontIndex)
    test "matches VB6 PrepareMessageConsoleMsg" do
      result = Encoder.encode({:console_msg, %{message: "Hello", font_index: 5}})

      expected =
        <<37::little-signed-16>> <>          # ServerPacketID.eConsoleMsg = 37
        <<5::little-signed-16, "Hello">> <>  # WriteString8("Hello") = Int16(5) + bytes
        <<5>>                                 # FontIndex = 5

      assert result == expected
    end
  end

  describe "eChatOverHead (ID 35) golden bytes" do
    # VB6: WriteInt16(35) + WriteString8(chat) + WriteInt16(charindex) +
    #      WriteInt32(Color) + WriteBool(EsSpell) + WriteInt8(x) + WriteInt8(y) +
    #      WriteInt16(RequiredMinDisplayTime) + WriteInt16(MaxDisplayTime)
    test "matches VB6 PrepareMessageChatOverHead" do
      result = Encoder.encode({:chat_over_head, %{
        message: "Hi",
        char_index: 7,
        color: 0x00FF0000,
        es_spell: false,
        x: 50,
        y: 60,
        min_display_time: 100,
        max_display_time: 500
      }})

      expected =
        <<35::little-signed-16>> <>           # eChatOverHead = 35
        <<2::little-signed-16, "Hi">> <>      # WriteString8("Hi")
        <<7::little-signed-16>> <>            # charindex = 7
        <<0x00FF0000::little-signed-32>> <>   # Color (BGR)
        <<0>> <>                               # EsSpell = False
        <<50>> <>                              # x
        <<60>> <>                              # y
        <<100::little-signed-16>> <>          # RequiredMinDisplayTime
        <<500::little-signed-16>>             # MaxDisplayTime

      assert result == expected
    end
  end

  describe "eUserIndexInServer (ID 46) golden bytes" do
    # VB6: WriteInt16(46) + WriteInt16(UserIndex)
    test "matches VB6 format" do
      result = Encoder.encode({:user_index_in_server, %{user_index: 42}})

      expected =
        <<46::little-signed-16>> <>
        <<42::little-signed-16>>

      assert result == expected
    end
  end

  describe "eCharacterCreate (ID 42) golden bytes" do
    # VB6: 40+ fields from PrepareMessageCharacterCreate (Protocol_Writes.bas:4001-4045)
    test "matches VB6 PrepareMessageCharacterCreate field order and types" do
      result = Encoder.encode({:character_create, %{
        char_index: 1,
        body_id: 100,
        head_id: 50,
        heading: 3,
        x: 45,
        y: 67,
        weapon_id: 10,
        shield_id: 5,
        helmet_id: 3,
        cart_id: 0,
        backpack_id: 0,
        fx: 0,
        fx_loops: 0,
        name: "Test",
        status: 0,
        privileges: 0,
        particula_fx: 0,
        head_aura: "",
        arma_aura: "",
        body_aura: "",
        dm_aura: "",
        rm_aura: "",
        otra_aura: "",
        escudo_aura: "",
        speed: 1.0,
        es_npc: 0,
        appear: 0,
        group_index: 0,
        clan_index: 0,
        clan_nivel: 0,
        min_hp: 100,
        max_hp: 200,
        min_mana: 50,
        max_mana: 150,
        simbolo: 0,
        idle: false,
        navegando: false,
        tipo_usuario: 0,
        team_captura: 0,
        tiene_bandera: 0,
        npc_num: 0
      }})

      # Build expected bytes following exact VB6 write order
      expected =
        <<42::little-signed-16>> <>        # PacketID
        <<1::little-signed-16>> <>         # charindex
        <<100::little-signed-16>> <>       # body
        <<50::little-signed-16>> <>        # head
        <<3>> <>                            # Heading
        <<45>> <>                           # x
        <<67>> <>                           # y
        <<10::little-signed-16>> <>        # weapon
        <<5::little-signed-16>> <>         # shield
        <<3::little-signed-16>> <>         # helmet
        <<0::little-signed-16>> <>         # Cart
        <<0::little-signed-16>> <>         # BackPack
        <<0::little-signed-16>> <>         # FX
        <<0::little-signed-16>> <>         # FXLoops
        <<4::little-signed-16, "Test">> <> # WriteString8(name)
        <<0>> <>                            # Status
        <<0>> <>                            # privileges
        <<0>> <>                            # ParticulaFx
        <<0::little-signed-16>> <>         # Head_Aura (empty string)
        <<0::little-signed-16>> <>         # Arma_Aura
        <<0::little-signed-16>> <>         # Body_Aura
        <<0::little-signed-16>> <>         # DM_Aura
        <<0::little-signed-16>> <>         # RM_Aura
        <<0::little-signed-16>> <>         # Otra_Aura
        <<0::little-signed-16>> <>         # Escudo_Aura
        <<0, 0, 128, 63>> <>              # speeding = 1.0 (IEEE 754 LE)
        <<0>> <>                            # EsNPC
        <<0>> <>                            # appear
        <<0::little-signed-16>> <>         # group_index
        <<0::little-signed-16>> <>         # clan_index
        <<0>> <>                            # clan_nivel
        <<100::little-signed-32>> <>       # UserMinHp
        <<200::little-signed-32>> <>       # UserMaxHp
        <<50::little-signed-32>> <>        # UserMinMAN
        <<150::little-signed-32>> <>       # UserMaxMAN
        <<0>> <>                            # Simbolo
        <<0>> <>                            # flags (Idle=0, Navegando=0)
        <<0>> <>                            # tipoUsuario
        <<0>> <>                            # TeamCaptura
        <<0>> <>                            # TieneBandera
        <<0::little-signed-16>>            # NpcNum

      assert result == expected
      assert byte_size(result) == byte_size(expected)
    end
  end

  describe "eCharacterChange (ID 49) golden bytes" do
    # VB6: WriteInt16(49) + WriteInt16(charindex) + WriteInt8(flags) +
    #      WriteInt16(body) + WriteInt16(head) + WriteInt8(heading) +
    #      WriteInt16(weapon) + WriteInt16(shield) + WriteInt16(helmet) +
    #      WriteInt16(cart) + WriteInt16(backpack) + WriteInt16(fx) + WriteInt16(fxloops)
    test "matches VB6 PrepareMessageCharacterChange" do
      result = Encoder.encode({:character_change, %{
        char_index: 5,
        body_id: 200,
        head_id: 30,
        heading: 2,
        weapon_id: 15,
        shield_id: 8,
        helmet_id: 4,
        idle: true,
        navegando: false
      }})

      expected =
        <<49::little-signed-16>> <>       # PacketID
        <<5::little-signed-16>> <>        # charindex
        <<1>> <>                           # flags (idle=1, navegando=0)
        <<200::little-signed-16>> <>      # body
        <<30::little-signed-16>> <>       # head
        <<2>> <>                           # heading
        <<15::little-signed-16>> <>       # weapon
        <<8::little-signed-16>> <>        # shield
        <<4::little-signed-16>> <>        # helmet
        <<0::little-signed-16>> <>        # cart
        <<0::little-signed-16>> <>        # backpack
        <<0::little-signed-16>> <>        # fx
        <<0::little-signed-16>>           # fxloops

      assert result == expected
    end
  end

  describe "eCharacterRemove (ID 43) golden bytes" do
    # VB6: WriteInt16(43) + WriteInt16(charindex) + WriteBool(desvanecido) + WriteBool(fue_warp)
    test "matches VB6 PrepareMessageCharacterRemove" do
      result = Encoder.encode({:character_remove, %{
        char_index: 12,
        desvanecido: true,
        fue_warp: false
      }})

      expected =
        <<43::little-signed-16>> <>       # PacketID
        <<12::little-signed-16>> <>       # charindex
        <<1>> <>                           # desvanecido = True
        <<0>>                              # fue_warp = False

      assert result == expected
    end
  end

  describe "eNpcHitUser (ID 32) golden bytes" do
    # VB6: WriteInt16(32) + WriteInt8(target/body_part) + WriteInt16(damage)
    test "matches VB6 format" do
      result = Encoder.encode({:npc_hit_user, %{target: 2, damage: 45}})

      expected =
        <<32::little-signed-16>> <>       # PacketID
        <<2>> <>                           # target/body_part
        <<45::little-signed-16>>          # damage

      assert result == expected
    end
  end

  describe "eUserHittedUser (ID 34) golden bytes" do
    # VB6: WriteInt16(34) + WriteInt16(charindex) + WriteInt8(target) + WriteInt16(damage)
    test "matches VB6 format" do
      result = Encoder.encode({:user_hitted_user, %{
        char_index: 7,
        target: 1,
        damage: 120
      }})

      expected =
        <<34::little-signed-16>> <>       # PacketID
        <<7::little-signed-16>> <>        # charindex
        <<1>> <>                           # target/body_part
        <<120::little-signed-16>>         # damage

      assert result == expected
    end
  end

  describe "eUserHittedByUser (ID 33) golden bytes" do
    # VB6: WriteInt16(33) + WriteInt16(attacker_charindex) + WriteInt8(target) + WriteInt16(damage)
    test "matches VB6 format" do
      result = Encoder.encode({:user_hitted_by_user, %{
        char_index: 3,
        target: 1,
        damage: 80
      }})

      expected =
        <<33::little-signed-16>> <>       # PacketID
        <<3::little-signed-16>> <>        # attacker_charindex
        <<1>> <>                           # target/body_part
        <<80::little-signed-16>>          # damage

      assert result == expected
    end
  end

  describe "eCreateFX (ID 60) golden bytes" do
    # VB6: WriteInt16(60) + WriteInt16(charindex) + WriteInt16(fx) + WriteInt16(loops) +
    #      WriteInt8(x) + WriteInt8(y)
    test "matches VB6 format" do
      result = Encoder.encode({:create_fx, %{
        char_index: 10,
        fx: 25,
        loops: 3,
        x: 50,
        y: 75
      }})

      expected =
        <<60::little-signed-16>> <>       # PacketID
        <<10::little-signed-16>> <>       # charindex
        <<25::little-signed-16>> <>       # fx
        <<3::little-signed-16>> <>        # loops
        <<50>> <>                          # x
        <<75>>                             # y

      assert result == expected
    end
  end

  describe "ePlayWave (ID 55) golden bytes" do
    # VB6: WriteInt16(55) + WriteInt16(wav) + WriteInt8(x) + WriteInt8(y) +
    #      WriteInt8(cancel_last) + WriteInt8(localize)
    test "matches VB6 format" do
      result = Encoder.encode({:play_wave, %{
        wav: 44,
        x: 60,
        y: 80,
        cancel_last: 0,
        localize: 1
      }})

      expected =
        <<55::little-signed-16>> <>       # PacketID
        <<44::little-signed-16>> <>       # wav
        <<60>> <>                          # x
        <<80>> <>                          # y
        <<0>> <>                           # cancel_last
        <<1>>                              # localize

      assert result == expected
    end
  end

  describe "eChangeSpellSlot (ID 66) golden bytes" do
    # VB6: WriteInt16(66) + WriteInt8(slot) + WriteInt16(spell_id) +
    #      WriteInt16(index) + WriteBool(is_bindable)
    test "matches VB6 format with valid spell" do
      result = Encoder.encode({:change_spell_slot, %{
        slot: 3,
        spell_id: 25,
        is_bindable: true
      }})

      expected =
        <<66::little-signed-16>> <>       # PacketID
        <<3>> <>                           # slot
        <<25::little-signed-16>> <>       # spell_id
        <<25::little-signed-16>> <>       # index (= spell_id when > 0)
        <<1>>                              # is_bindable

      assert result == expected
    end

    test "index is -1 when spell_id is 0 (empty slot)" do
      result = Encoder.encode({:change_spell_slot, %{
        slot: 1,
        spell_id: 0
      }})

      expected =
        <<66::little-signed-16>> <>
        <<1>> <>
        <<0::little-signed-16>> <>
        <<-1::little-signed-16>> <>
        <<0>>

      assert result == expected
    end
  end

  describe "eChangeNPCInventorySlot (ID 77) golden bytes" do
    # VB6: WriteInt16(77) + WriteInt8(slot) + WriteInt16(obj_index) + WriteInt16(amount) +
    #      WriteReal32(price) + WriteInt32(elemental_tags) + WriteInt8(puede_usar)
    test "matches VB6 format" do
      result = Encoder.encode({:change_npc_inventory_slot, %{
        slot: 2,
        obj_index: 150,
        amount: 10,
        price: 50.0,
        elemental_tags: 0,
        puede_usar: 1
      }})

      expected =
        <<77::little-signed-16>> <>       # PacketID
        <<2>> <>                           # slot
        <<150::little-signed-16>> <>      # obj_index
        <<10::little-signed-16>> <>       # amount
        <<0, 0, 72, 66>> <>              # price = 50.0 (IEEE 754 LE)
        <<0::little-signed-32>> <>        # elemental_tags
        <<1>>                              # puede_usar

      assert result == expected
    end
  end

  describe "eConnected (ID 1) golden bytes" do
    # VB6: WriteInt16(1) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:connected, %{}})

      expected = <<1::little-signed-16>>

      assert result == expected
    end
  end

  describe "eDisconnect (ID 7) golden bytes" do
    # VB6: WriteInt16(7) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:disconnect, %{}})

      expected = <<7::little-signed-16>>

      assert result == expected
    end
  end

  describe "eUserCharIndexInServer (ID 47) golden bytes" do
    # VB6: WriteInt16(47) + WriteInt16(charIndex)
    test "matches VB6 format" do
      result = Encoder.encode({:user_char_index_in_server, %{char_index: 99}})

      expected =
        <<47::little-signed-16>> <>
        <<99::little-signed-16>>

      assert result == expected
    end
  end

  describe "eCharacterMove (ID 44) golden bytes" do
    # VB6: WriteInt16(44) + WriteInt16(charindex) + WriteInt8(x) + WriteInt8(y)
    test "matches VB6 format" do
      result = Encoder.encode({:character_move, %{char_index: 10, x: 25, y: 30}})

      expected =
        <<44::little-signed-16>> <>
        <<10::little-signed-16>> <>
        <<25>> <>
        <<30>>

      assert result == expected
    end
  end

  describe "eUpdateExp (ID 29) golden bytes" do
    # VB6: WriteInt16(29) + WriteInt32(CurrentXP) + WriteInt32(NextXP)
    test "matches VB6 format" do
      result = Encoder.encode({:update_exp, %{current_xp: 15000, next_xp: 30000}})

      expected =
        <<29::little-signed-16>> <>
        <<15000::little-signed-32>> <>
        <<30000::little-signed-32>>

      assert result == expected
    end
  end

  describe "eErrorMsg (ID 73) golden bytes" do
    # VB6: WriteInt16(73) + WriteString8(message)
    test "matches VB6 format" do
      result = Encoder.encode({:error_msg, %{message: "Hello"}})

      expected =
        <<73::little-signed-16>> <>
        <<5::little-signed-16, "Hello">>

      assert result == expected
    end
  end

  describe "eIntervals (ID 158) golden bytes" do
    # VB6: WriteInt16(158) + 12 × WriteInt32
    test "matches VB6 format" do
      result = Encoder.encode({:intervals, %{
        bow: 100,
        walk: 210,
        melee: 300,
        melee_magic: 400,
        magic: 500,
        magic_melee: 600,
        melee_use: 700,
        work_extract: 800,
        work_build: 900,
        use_item: 1000,
        use_click: 1100,
        drop: 1200
      }})

      expected =
        <<158::little-signed-16>> <>
        <<100::little-signed-32>> <>
        <<210::little-signed-32>> <>
        <<300::little-signed-32>> <>
        <<400::little-signed-32>> <>
        <<500::little-signed-32>> <>
        <<600::little-signed-32>> <>
        <<700::little-signed-32>> <>
        <<800::little-signed-32>> <>
        <<900::little-signed-32>> <>
        <<1000::little-signed-32>> <>
        <<1100::little-signed-32>> <>
        <<1200::little-signed-32>>

      assert result == expected
    end
  end

  describe "eChangeInventorySlot (ID 63) golden bytes" do
    # VB6: WriteInt16(63) + WriteInt8(slot) + WriteInt16(obj_index) + WriteInt16(amount) +
    #      WriteBool(equipped) + WriteReal32(valor) + WriteInt8(puede_usar) +
    #      WriteInt32(elemental_tags) + WriteBool(is_bindable)
    test "matches VB6 format" do
      result = Encoder.encode({:change_inventory_slot, %{
        slot: 1,
        obj_index: 200,
        amount: 5,
        equipped: true,
        valor: 1.0,
        puede_usar: 1,
        elemental_tags: 7,
        is_bindable: false
      }})

      expected =
        <<63::little-signed-16>> <>
        <<1>> <>
        <<200::little-signed-16>> <>
        <<5::little-signed-16>> <>
        <<1>> <>
        <<0, 0, 128, 63>> <>
        <<1>> <>
        <<7::little-signed-32>> <>
        <<0>>

      assert result == expected
    end
  end

  describe "eObjectCreate (ID 50) golden bytes" do
    # VB6: WriteInt16(50) + WriteInt8(x) + WriteInt8(y) + WriteInt16(obj_index) +
    #      WriteInt16(amount) + WriteInt32(elemental_tags)
    test "matches VB6 format" do
      result = Encoder.encode({:object_create, %{
        x: 10,
        y: 20,
        obj_index: 150,
        amount: 3,
        elemental_tags: 0
      }})

      expected =
        <<50::little-signed-16>> <>
        <<10>> <>
        <<20>> <>
        <<150::little-signed-16>> <>
        <<3::little-signed-16>> <>
        <<0::little-signed-32>>

      assert result == expected
    end
  end

  describe "eObjectDelete (ID 52) golden bytes" do
    # VB6: WriteInt16(52) + WriteInt8(x) + WriteInt8(y)
    test "matches VB6 format" do
      result = Encoder.encode({:object_delete, %{x: 15, y: 25}})

      expected =
        <<52::little-signed-16>> <>
        <<15>> <>
        <<25>>

      assert result == expected
    end
  end

  describe "eUpdateHungerAndThirst (ID 78) golden bytes" do
    # VB6: WriteInt16(78) + WriteInt8(max_thirst) + WriteInt8(min_thirst) +
    #      WriteInt8(max_hunger) + WriteInt8(min_hunger)
    test "matches VB6 format" do
      result = Encoder.encode({:update_hunger_and_thirst, %{
        max_thirst: 100,
        min_thirst: 80,
        max_hunger: 100,
        min_hunger: 60
      }})

      expected =
        <<78::little-signed-16>> <>
        <<100>> <>
        <<80>> <>
        <<100>> <>
        <<60>>

      assert result == expected
    end
  end

  describe "eLevelUp (ID 80) golden bytes" do
    # VB6: WriteInt16(80) + WriteInt16(level)
    test "matches VB6 format" do
      result = Encoder.encode({:level_up, %{level: 25}})

      expected =
        <<80::little-signed-16>> <>
        <<25::little-signed-16>>

      assert result == expected
    end
  end

  describe "session_token (ID 200) golden bytes" do
    # WS-only: WriteInt16(200) + WriteInt32(char_id) + WriteString8(token)
    test "matches expected format" do
      result = Encoder.encode({:session_token, %{char_id: 42, token: "abc"}})

      expected =
        <<200::little-signed-16>> <>
        <<42::little-signed-32>> <>
        <<3::little-signed-16, "abc">>

      assert result == expected
    end
  end

  describe "eCharSwing (ID 19) golden bytes" do
    # VB6: WriteInt16(19) + WriteInt16(charindex)
    test "matches VB6 format" do
      result = Encoder.encode({:char_swing, %{char_index: 55}})

      expected =
        <<19::little-signed-16>> <>
        <<55::little-signed-16>>

      assert result == expected
    end
  end

  describe "eBlockedWithShieldUser (ID 17) golden bytes" do
    # VB6: WriteInt16(17) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:blocked_with_shield_user, %{}})

      expected = <<17::little-signed-16>>

      assert result == expected
    end
  end

  describe "eBlockedWithShieldOther (ID 18) golden bytes" do
    # VB6: WriteInt16(18) + WriteInt16(charindex)
    test "matches VB6 format" do
      result = Encoder.encode({:blocked_with_shield_other, %{char_index: 33}})

      expected =
        <<18::little-signed-16>> <>
        <<33::little-signed-16>>

      assert result == expected
    end
  end

  describe "eNpcKillUser (ID 16) golden bytes" do
    # VB6: WriteInt16(16) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:npc_kill_user, %{}})

      expected = <<16::little-signed-16>>

      assert result == expected
    end
  end

  describe "eSafeModeOn (ID 20) golden bytes" do
    # VB6: WriteInt16(20) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:safe_mode_on, %{}})

      expected = <<20::little-signed-16>>

      assert result == expected
    end
  end

  describe "eSafeModeOff (ID 21) golden bytes" do
    # VB6: WriteInt16(21) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:safe_mode_off, %{}})

      expected = <<21::little-signed-16>>

      assert result == expected
    end
  end

  describe "eSendSkills (ID 87) golden bytes" do
    # VB6: WriteInt16(87) + 24 × WriteInt8 in VB6 order
    test "matches VB6 format" do
      skills = %{
        magic: 10, stealing: 20, combat_tactics: 30, combat_weapons: 40,
        meditation: 50, short_weapons: 60, hiding: 70, survival: 80,
        trading: 90, combat_defense: 100, leadership: 11, ranged_weapons: 22,
        wrestling: 33, navigation: 44, riding: 55, resistance: 66,
        woodcutting: 77, fishing: 88, mining: 99, blacksmithing: 15,
        carpentry: 25, alchemy: 35, tailoring: 45, taming: 5
      }
      result = Encoder.encode({:send_skills, %{skills: skills}})

      expected =
        <<87::little-signed-16>> <>
        <<10>> <> <<20>> <> <<30>> <> <<40>> <>
        <<50>> <> <<60>> <> <<70>> <> <<80>> <>
        <<90>> <> <<100>> <> <<11>> <> <<22>> <>
        <<33>> <> <<44>> <> <<55>> <> <<66>> <>
        <<77>> <> <<88>> <> <<99>> <> <<15>> <>
        <<25>> <> <<35>> <> <<45>> <> <<5>>

      assert result == expected
    end
  end

  describe "eCommerceInit (ID 10) golden bytes" do
    # VB6: WriteInt16(10) + WriteString8(npc_name)
    test "matches VB6 format" do
      result = Encoder.encode({:commerce_init, %{npc_name: "Merchant"}})

      expected =
        <<10::little-signed-16>> <>
        <<8::little-signed-16, "Merchant">>

      assert result == expected
    end
  end

  describe "eCommerceEnd (ID 8) golden bytes" do
    # VB6: WriteInt16(8) — no payload
    test "matches VB6 format" do
      result = Encoder.encode({:commerce_end, %{}})

      expected = <<8::little-signed-16>>

      assert result == expected
    end
  end

  describe "eNavigateToggle (ID 5) golden bytes" do
    test "matches VB6 WriteNavigateToggle with true" do
      result = Encoder.encode({:navigate_toggle, %{new_state: true}})
      expected = <<5::little-signed-16, 1>>
      assert result == expected
    end

    test "matches VB6 WriteNavigateToggle with false" do
      result = Encoder.encode({:navigate_toggle, %{new_state: false}})
      expected = <<5::little-signed-16, 0>>
      assert result == expected
    end
  end

  describe "eShowMessageBox (ID 40) golden bytes" do
    test "matches VB6 WriteShowMessageBox with extra text" do
      result = Encoder.encode({:show_message_box, %{message_id: 3, extra: "Hello"}})

      expected =
        <<40::little-signed-16>> <>
        <<3::little-signed-16>> <>
        <<5::little-signed-16, "Hello">>

      assert result == expected
    end

    test "matches VB6 WriteShowMessageBox with empty extra" do
      result = Encoder.encode({:show_message_box, %{message_id: 1}})

      expected =
        <<40::little-signed-16>> <>
        <<1::little-signed-16>> <>
        <<0::little-signed-16>>

      assert result == expected
    end
  end

  describe "ePlayMidi (ID 54) golden bytes" do
    test "matches VB6 WritePlayMidi" do
      result = Encoder.encode({:play_midi, %{midi: 8, loops: 3}})

      expected =
        <<54::little-signed-16>> <>
        <<8>> <>
        <<3::little-signed-16>>

      assert result == expected
    end

    test "defaults loops to -1" do
      result = Encoder.encode({:play_midi, %{midi: 1}})

      expected =
        <<54::little-signed-16>> <>
        <<1>> <>
        <<-1::little-signed-16>>

      assert result == expected
    end
  end

  describe "eAreaChanged (ID 57) golden bytes" do
    test "matches VB6 WriteAreaChanged" do
      result = Encoder.encode({:area_changed, %{x: 50, y: 75}})

      expected =
        <<57::little-signed-16>> <>
        <<50>> <>
        <<75>>

      assert result == expected
    end
  end

  describe "ePauseToggle (ID 58) golden bytes" do
    test "matches VB6 PrepareMessagePauseToggle" do
      result = Encoder.encode({:pause_toggle, %{}})
      expected = <<58::little-signed-16>>
      assert result == expected
    end
  end

  describe "eRainToggle (ID 59) golden bytes" do
    test "matches VB6 WriteRainToggle raining" do
      result = Encoder.encode({:rain_toggle, %{raining: true}})
      expected = <<59::little-signed-16, 1>>
      assert result == expected
    end

    test "matches VB6 WriteRainToggle not raining" do
      result = Encoder.encode({:rain_toggle, %{raining: false}})
      expected = <<59::little-signed-16, 0>>
      assert result == expected
    end
  end

  describe "eBlind (ID 74) golden bytes" do
    test "matches VB6 WriteBlind" do
      result = Encoder.encode({:blind, %{}})
      expected = <<74::little-signed-16>>
      assert result == expected
    end
  end

  describe "eDumb (ID 75) golden bytes" do
    test "matches VB6 WriteDumb" do
      result = Encoder.encode({:dumb, %{}})
      expected = <<75::little-signed-16>>
      assert result == expected
    end
  end

  describe "eMiniStats (ID 79) golden bytes" do
    test "matches VB6 WriteMiniStats" do
      result = Encoder.encode({:mini_stats, %{
        ciudadanos_matados: 5,
        criminales_matados: 10,
        faction_status: 1,
        npcs_killed: 200,
        class: 6,
        penalty: 0,
        deaths: 3,
        gender: 1,
        fishing_points: 50,
        race: 2
      }})

      expected =
        <<79::little-signed-16>> <>
        <<5::little-signed-32>> <>
        <<10::little-signed-32>> <>
        <<1>> <>
        <<200::little-signed-32>> <>
        <<6>> <>
        <<0::little-signed-32>> <>
        <<3::little-signed-32>> <>
        <<1>> <>
        <<50::little-signed-32>> <>
        <<2>>

      assert result == expected
    end
  end

  describe "eUpdateUserStats (ID 61) golden bytes" do
    test "matches VB6 WriteUpdateUserStats" do
      result = Encoder.encode({:update_user_stats, %{
        max_hp: 300,
        min_hp: 250,
        shield: 15,
        max_mana: 500,
        min_mana: 400,
        max_sta: 100,
        min_sta: 80,
        gold: 5000,
        gold_cap: 100_000,
        level: 25,
        exp_next_level: 50_000,
        exp: 30_000,
        class: 6
      }})

      expected =
        <<61::little-signed-16>> <>
        <<300::little-signed-16>> <>
        <<250::little-signed-16>> <>
        <<15::little-signed-32>> <>
        <<500::little-signed-16>> <>
        <<400::little-signed-16>> <>
        <<100::little-signed-16>> <>
        <<80::little-signed-16>> <>
        <<5000::little-signed-32>> <>
        <<100_000::little-signed-32>> <>
        <<25>> <>
        <<50_000::little-signed-32>> <>
        <<30_000::little-signed-32>> <>
        <<6>>

      assert result == expected
    end
  end

  # ============================================================
  # Client → Server decoder golden tests
  # ============================================================

  describe "eLoginExistingChar (ID 73) decode" do
    # VB6: WriteInt16(73) + WriteString8(token) + WriteInt32(char_id) +
    #      WriteInt8(major) + WriteInt8(minor) + WriteInt8(build) + WriteString8(md5)
    test "decodes AO20 login packet" do
      token = "test_token"
      md5 = "abc123"

      packet =
        <<73::little-signed-16>> <>                  # PacketID
        <<10::little-signed-16, token::binary>> <>   # session_token
        <<42::little-signed-32>> <>                   # char_id
        <<1>> <> <<2>> <> <<3>> <>                    # version 1.2.3
        <<6::little-signed-16, md5::binary>>         # md5

      assert {:ok, {:login_existing_char, params}, <<>>} = Decoder.decode(packet)
      assert params.session_token == "test_token"
      assert params.char_id == 42
      assert params.version == "1.2.3"
      assert params.md5 == "abc123"
    end
  end

  describe "eWalk (ID 78) decode" do
    # VB6: WriteInt16(78) + WriteInt8(Heading) + WriteInt32(PacketCount)
    test "decodes walk north" do
      packet = <<78::little-signed-16, 1, 5::little-signed-32>>
      assert {:ok, {:walk, %{direction: :north}}, <<>>} = Decoder.decode(packet)
    end

    test "decodes walk east" do
      packet = <<78::little-signed-16, 2, 1::little-signed-32>>
      assert {:ok, {:walk, %{direction: :east}}, <<>>} = Decoder.decode(packet)
    end

    test "decodes walk south" do
      packet = <<78::little-signed-16, 3, 1::little-signed-32>>
      assert {:ok, {:walk, %{direction: :south}}, <<>>} = Decoder.decode(packet)
    end

    test "decodes walk west" do
      packet = <<78::little-signed-16, 4, 1::little-signed-32>>
      assert {:ok, {:walk, %{direction: :west}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eTalk (ID 75) decode" do
    # VB6: WriteInt16(75) + WriteString8(message) + WriteInt32(packet_count)
    test "decodes talk message" do
      msg = "Hello!"
      packet = <<75::little-signed-16, 6::little-signed-16, msg::binary, 1::little-signed-32>>
      assert {:ok, {:talk, %{message: "Hello!"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eAttack (ID 80) decode" do
    # VB6: WriteInt16(80) + WriteInt32(packet_count)
    test "decodes attack" do
      packet = <<80::little-signed-16, 1::little-signed-32>>
      assert {:ok, {:attack, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eCastSpell (ID 94) decode" do
    # VB6: WriteInt16(94) + WriteInt8(SpellSlot) + WriteInt32(packet_count)
    test "decodes cast spell" do
      packet = <<94::little-signed-16, 3, 1::little-signed-32>>
      assert {:ok, {:cast_spell, %{spell_slot: 3}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eDrop (ID 93) decode" do
    # VB6: WriteInt16(93) + WriteInt8(slot) + WriteInt32(amount) + WriteInt32(packet_count)
    test "decodes drop with Int32 amount" do
      packet = <<93::little-signed-16, 5, 100::little-signed-32, 1::little-signed-32>>
      assert {:ok, {:drop, %{slot: 5, amount: 100}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eEquipItem (ID 5) decode" do
    # VB6: WriteInt16(5) + WriteInt8(slot) + WriteBool(is_skin) + [WriteInt8(skin_type)] +
    #      WriteInt32(packet_count)
    test "decodes equip without skin" do
      packet = <<5::little-signed-16, 3, 0, 1::little-signed-32>>
      assert {:ok, {:equip_item, %{slot: 3}}, <<>>} = Decoder.decode(packet)
    end

    test "decodes equip with skin" do
      packet = <<5::little-signed-16, 3, 1, 2, 1::little-signed-32>>
      assert {:ok, {:equip_item, %{slot: 3}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eUseItem (ID 99) decode" do
    # VB6: WriteInt16(99) + WriteInt8(slot) + WriteInt8(is_main_inventory) + WriteInt32(packet_count)
    test "decodes use item" do
      packet = <<99::little-signed-16, 7, 1, 1::little-signed-32>>
      assert {:ok, {:use_item, %{slot: 7}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eChangeHeading (ID 6) decode" do
    # VB6: WriteInt16(6) + WriteInt8(heading) + WriteInt32(packet_count)
    test "decodes change heading" do
      packet = <<6::little-signed-16, 3, 1::little-signed-32>>
      assert {:ok, {:change_heading, %{heading: 3}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eLeftClick (ID 95) decode" do
    # VB6: WriteInt16(95) + WriteInt8(x) + WriteInt8(y) + WriteInt32(packet_count)
    test "decodes left click" do
      packet = <<95::little-signed-16, 50, 75, 1::little-signed-32>>
      assert {:ok, {:left_click, %{x: 50, y: 75}}, <<>>} = Decoder.decode(packet)
    end
  end

  # ============================================================
  # Client → Server decoder golden tests (remaining packets)
  # ============================================================

  describe "eLoginNewChar (ID 74) decode" do
    test "decodes new character creation packet" do
      token = "tok123"
      name = "Hero"
      md5 = "md5hash"

      packet =
        <<74::little-signed-16,
          byte_size(token)::little-signed-16, token::binary,
          byte_size(name)::little-signed-16, name::binary,
          0::8, 13::8, 2::8,
          byte_size(md5)::little-signed-16, md5::binary,
          1::8, 2::8, 3::8,
          5::little-signed-16,
          4::8>>

      assert {:ok, {:login_new_char, params}, <<>>} = Decoder.decode(packet)
      assert params.session_token == "tok123"
      assert params.username == "Hero"
      assert params.version == "0.13.2"
      assert params.md5 == "md5hash"
      assert params.race == 1
      assert params.gender == 2
      assert params.class == 3
      assert params.head == 5
      assert params.home_city == 4
    end
  end

  describe "eYell (ID 76) decode" do
    test "decodes yell message" do
      msg = "HELLO!"
      packet = <<76::little-signed-16, byte_size(msg)::little-signed-16, msg::binary>>
      assert {:ok, {:yell, %{message: "HELLO!"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eWhisper (ID 77) decode" do
    test "decodes whisper with target and message" do
      target = "Admin"
      msg = "secret"
      packet =
        <<77::little-signed-16,
          byte_size(target)::little-signed-16, target::binary,
          byte_size(msg)::little-signed-16, msg::binary>>

      assert {:ok, {:whisper, %{target_name: "Admin", message: "secret"}}, <<>>} =
               Decoder.decode(packet)
    end
  end

  describe "eRequestPositionUpdate (ID 79) decode" do
    test "decodes with no payload" do
      packet = <<79::little-signed-16>>
      assert {:ok, {:request_position_update, %{}}, <<>>} = Decoder.decode(packet)
    end

    test "preserves trailing bytes" do
      extra = <<0xFF>>
      packet = <<79::little-signed-16>> <> extra
      assert {:ok, {:request_position_update, %{}}, ^extra} = Decoder.decode(packet)
    end
  end

  describe "ePickUp (ID 81) decode" do
    test "decodes with no payload" do
      packet = <<81::little-signed-16>>
      assert {:ok, {:pick_up, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eSafeToggle (ID 82) decode" do
    test "decodes with no payload" do
      packet = <<82::little-signed-16>>
      assert {:ok, {:safe_toggle, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eQuit (ID 39) decode" do
    test "decodes with no payload" do
      packet = <<39::little-signed-16>>
      assert {:ok, {:quit, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eCommerceStart (ID 53) decode" do
    test "decodes with no payload" do
      packet = <<53::little-signed-16>>
      assert {:ok, {:commerce_start, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eCommerceBuy (ID 9) decode" do
    test "decodes slot and amount" do
      packet = <<9::little-signed-16, 3::8, 10::little-signed-16>>
      assert {:ok, {:commerce_buy, %{slot: 3, amount: 10}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eCommerceSell (ID 11) decode" do
    test "decodes slot and amount" do
      packet = <<11::little-signed-16, 5::8, 25::little-signed-16>>
      assert {:ok, {:commerce_sell, %{slot: 5, amount: 25}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eCommerceEnd (ID 88) decode" do
    test "decodes with no payload" do
      packet = <<88::little-signed-16>>
      assert {:ok, {:commerce_end, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eBankStart (ID 54) decode" do
    test "decodes with no payload" do
      packet = <<54::little-signed-16>>
      assert {:ok, {:bank_start, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eBankEnd (ID 90) decode" do
    test "decodes with no payload" do
      packet = <<90::little-signed-16>>
      assert {:ok, {:bank_end, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eBankExtractItem (ID 10) decode" do
    test "decodes slot, amount, and destination slot" do
      packet = <<10::little-signed-16, 2::8, 50::little-signed-16, 7::8>>
      assert {:ok, {:bank_extract_item, %{slot: 2, amount: 50, slot_destino: 7}}, <<>>} =
               Decoder.decode(packet)
    end
  end

  describe "eBankDeposit (ID 12) decode" do
    test "decodes slot, amount, and destination slot" do
      packet = <<12::little-signed-16, 4::8, 100::little-signed-16, 3::8>>
      assert {:ok, {:bank_deposit, %{slot: 4, amount: 100, slot_destino: 3}}, <<>>} =
               Decoder.decode(packet)
    end
  end

  describe "eBankExtractGold (ID 70) decode" do
    test "decodes amount" do
      packet = <<70::little-signed-16, 5000::little-signed-32>>
      assert {:ok, {:bank_extract_gold, %{amount: 5000}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eBankDepositGold (ID 71) decode" do
    test "decodes amount" do
      packet = <<71::little-signed-16, 3000::little-signed-32>>
      assert {:ok, {:bank_deposit_gold, %{amount: 3000}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eDoubleClick (ID 96) decode" do
    test "decodes x and y" do
      packet = <<96::little-signed-16, 10::8, 20::8>>
      assert {:ok, {:double_click, %{x: 10, y: 20}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eWork (ID 97) decode" do
    test "decodes skill and consumes packet_count" do
      packet = <<97::little-signed-16, 7::8, 1::little-signed-32>>
      assert {:ok, {:work, %{skill: 7}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eOnline (ID 38) decode" do
    test "decodes with no payload" do
      packet = <<38::little-signed-16>>
      assert {:ok, {:online, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eRest (ID 47) decode" do
    test "decodes with no payload" do
      packet = <<47::little-signed-16>>
      assert {:ok, {:rest, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eMeditate (ID 48) decode" do
    test "decodes with no payload" do
      packet = <<48::little-signed-16>>
      assert {:ok, {:meditate, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eResucitate (ID 49) decode" do
    test "decodes with no payload" do
      packet = <<49::little-signed-16>>
      assert {:ok, {:resucitate, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eHeal (ID 50) decode" do
    test "decodes with no payload" do
      packet = <<50::little-signed-16>>
      assert {:ok, {:heal, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "ePartySafeToggle (ID 83) decode" do
    test "decodes with no payload" do
      packet = <<83::little-signed-16>>
      assert {:ok, {:party_safe_toggle, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eRequestAtributes (ID 85) decode" do
    test "decodes with no payload" do
      packet = <<85::little-signed-16>>
      assert {:ok, {:request_atributes, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eRequestSkills (ID 86) decode" do
    test "decodes with no payload" do
      packet = <<86::little-signed-16>>
      assert {:ok, {:request_skills, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eRequestMiniStats (ID 87) decode" do
    test "decodes with no payload" do
      packet = <<87::little-signed-16>>
      assert {:ok, {:request_mini_stats, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eUseSpellMacro (ID 98) decode" do
    test "decodes with no payload" do
      packet = <<98::little-signed-16>>
      assert {:ok, {:use_spell_macro, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  # ============================================================
  # Stream integrity: every decoder preserves trailing bytes
  # ============================================================

  describe "all payload decoders preserve trailing bytes" do
    test "login_new_char (74) preserves rest" do
      token = "t"
      name = "N"
      md5 = "m"
      extra = <<0xAB>>

      packet =
        <<74::little-signed-16,
          1::little-signed-16, token::binary,
          1::little-signed-16, name::binary,
          0::8, 0::8, 1::8,
          1::little-signed-16, md5::binary,
          1::8, 1::8, 1::8, 1::little-signed-16, 1::8>> <> extra

      assert {:ok, {:login_new_char, _}, ^extra} = Decoder.decode(packet)
    end

    test "yell (76) preserves rest" do
      extra = <<0xCD>>
      packet = <<76::little-signed-16, 1::little-signed-16, "Y">> <> extra
      assert {:ok, {:yell, _}, ^extra} = Decoder.decode(packet)
    end

    test "whisper (77) preserves rest" do
      extra = <<0xEF>>
      packet = <<77::little-signed-16, 1::little-signed-16, "A", 1::little-signed-16, "B">> <> extra
      assert {:ok, {:whisper, _}, ^extra} = Decoder.decode(packet)
    end

    test "commerce_buy (9) preserves rest" do
      extra = <<0x11>>
      packet = <<9::little-signed-16, 1::8, 1::little-signed-16>> <> extra
      assert {:ok, {:commerce_buy, _}, ^extra} = Decoder.decode(packet)
    end

    test "commerce_sell (11) preserves rest" do
      extra = <<0x22>>
      packet = <<11::little-signed-16, 1::8, 1::little-signed-16>> <> extra
      assert {:ok, {:commerce_sell, _}, ^extra} = Decoder.decode(packet)
    end

    test "bank_extract_item (10) preserves rest" do
      extra = <<0x33>>
      packet = <<10::little-signed-16, 1::8, 1::little-signed-16, 1::8>> <> extra
      assert {:ok, {:bank_extract_item, _}, ^extra} = Decoder.decode(packet)
    end

    test "bank_deposit (12) preserves rest" do
      extra = <<0x44>>
      packet = <<12::little-signed-16, 1::8, 1::little-signed-16, 1::8>> <> extra
      assert {:ok, {:bank_deposit, _}, ^extra} = Decoder.decode(packet)
    end

    test "bank_extract_gold (70) preserves rest" do
      extra = <<0x55>>
      packet = <<70::little-signed-16, 1::little-signed-32>> <> extra
      assert {:ok, {:bank_extract_gold, _}, ^extra} = Decoder.decode(packet)
    end

    test "bank_deposit_gold (71) preserves rest" do
      extra = <<0x66>>
      packet = <<71::little-signed-16, 1::little-signed-32>> <> extra
      assert {:ok, {:bank_deposit_gold, _}, ^extra} = Decoder.decode(packet)
    end

    test "double_click (96) preserves rest" do
      extra = <<0x77>>
      packet = <<96::little-signed-16, 1::8, 1::8>> <> extra
      assert {:ok, {:double_click, _}, ^extra} = Decoder.decode(packet)
    end

    test "work (97) preserves rest" do
      extra = <<0x88>>
      packet = <<97::little-signed-16, 1::8, 1::little-signed-32>> <> extra
      assert {:ok, {:work, _}, ^extra} = Decoder.decode(packet)
    end
  end

  # ============================================================
  # Buffer handling / incomplete packet tests
  # ============================================================

  describe "incomplete packet handling" do
    test "returns incomplete for empty buffer" do
      assert :incomplete = Decoder.decode(<<>>)
    end

    test "returns incomplete for single byte" do
      assert :incomplete = Decoder.decode(<<73>>)
    end

    test "returns incomplete when string data is truncated" do
      # Login packet with truncated token string
      packet = <<73::little-signed-16, 100::little-signed-16, "short">>
      assert :incomplete = Decoder.decode(packet)
    end

    test "preserves remaining data after successful decode" do
      msg = "Hi"
      extra = <<99, 88>>
      packet = <<75::little-signed-16, 2::little-signed-16, msg::binary, 1::little-signed-32>> <> extra
      assert {:ok, {:talk, %{message: "Hi"}}, ^extra} = Decoder.decode(packet)
    end
  end

  # ============================================================
  # Multi-packet buffer decode test
  # ============================================================

  describe "multiple packets in buffer" do
    test "decodes first packet and preserves rest" do
      talk1 = <<75::little-signed-16, 2::little-signed-16, "Hi", 1::little-signed-32>>
      talk2 = <<75::little-signed-16, 5::little-signed-16, "World", 2::little-signed-32>>
      buffer = talk1 <> talk2

      assert {:ok, {:talk, %{message: "Hi"}}, rest} = Decoder.decode(buffer)
      assert {:ok, {:talk, %{message: "World"}}, <<>>} = Decoder.decode(rest)
    end
  end

  # ============================================================
  # Unhandled packet ID stream desync tests
  # ============================================================

  describe "unhandled packet IDs" do
    # These packet IDs are defined in PacketIds.Client but have no decoder clause.
    # A VB6 client will send them. The decoder must not break the stream.

    test "rest (47) is decoded without breaking the stream" do
      # rest has no payload in VB6
      rest_packet = <<47::little-signed-16>>
      talk_after = <<75::little-signed-16, 2::little-signed-16, "Hi", 1::little-signed-32>>
      buffer = rest_packet <> talk_after

      # First decode should succeed (not error)
      assert {:ok, _, remaining} = Decoder.decode(buffer)
      # The talk packet after it should still be parseable
      assert {:ok, {:talk, %{message: "Hi"}}, <<>>} = Decoder.decode(remaining)
    end

    test "meditate (48) is decoded without breaking the stream" do
      buffer = <<48::little-signed-16>> <> <<75::little-signed-16, 2::little-signed-16, "Hi", 1::little-signed-32>>
      assert {:ok, _, remaining} = Decoder.decode(buffer)
      assert {:ok, {:talk, %{message: "Hi"}}, <<>>} = Decoder.decode(remaining)
    end

    test "online (38) is decoded without breaking the stream" do
      buffer = <<38::little-signed-16>> <> <<75::little-signed-16, 2::little-signed-16, "Hi", 1::little-signed-32>>
      assert {:ok, _, remaining} = Decoder.decode(buffer)
      assert {:ok, {:talk, %{message: "Hi"}}, <<>>} = Decoder.decode(remaining)
    end
  end

  # ============================================================
  # Crafting UI packets
  # ============================================================

  describe "crafting decoder golden bytes" do
    test "CraftAlquimista (228) decodes item I16" do
      buffer = <<228::little-signed-16, 37::little-signed-16>>
      assert {:ok, {:craft_alchemy, %{item: 37}}, <<>>} = Decoder.decode(buffer)
    end

    test "CraftSastre (230) decodes item I16" do
      buffer = <<230::little-signed-16, 3578::little-signed-16>>
      assert {:ok, {:craft_tailor, %{item: 3578}}, <<>>} = Decoder.decode(buffer)
    end

    test "CraftBlacksmith (100) decodes item I16" do
      buffer = <<100::little-signed-16, 386::little-signed-16>>
      assert {:ok, {:craft_blacksmith, %{item: 386}}, <<>>} = Decoder.decode(buffer)
    end

    test "CraftCarpenter (1) decodes item I16 + amount I32" do
      buffer = <<1::little-signed-16, 480::little-signed-16, 5::little-signed-32>>
      assert {:ok, {:craft_carpenter, %{item: 480, amount: 5}}, <<>>} = Decoder.decode(buffer)
    end
  end

  describe "crafting encoder golden bytes" do
    test "show_blacksmith_form encodes as no-payload ID 14" do
      result = Encoder.encode({:show_blacksmith_form, %{}})
      assert result == <<14::little-signed-16>>
    end

    test "show_carpenter_form encodes as no-payload ID 15" do
      result = Encoder.encode({:show_carpenter_form, %{}})
      assert result == <<15::little-signed-16>>
    end

    test "show_alchemy_form encodes as no-payload ID 131" do
      result = Encoder.encode({:show_alchemy_form, %{}})
      assert result == <<131::little-signed-16>>
    end

    test "show_tailor_form encodes as no-payload ID 133" do
      result = Encoder.encode({:show_tailor_form, %{}})
      assert result == <<133::little-signed-16>>
    end

    test "blacksmith_weapons encodes count(I16) + items(I16 each)" do
      result = Encoder.encode({:blacksmith_weapons, %{items: [386, 15]}})
      expected =
        <<68::little-signed-16>> <>
        <<2::little-signed-16>> <>
        <<386::little-signed-16>> <>
        <<15::little-signed-16>>
      assert result == expected
    end

    test "blacksmith_armors encodes count(I16) + items(I16 each)" do
      result = Encoder.encode({:blacksmith_armors, %{items: [1912]}})
      expected =
        <<69::little-signed-16>> <>
        <<1::little-signed-16>> <>
        <<1912::little-signed-16>>
      assert result == expected
    end

    test "carpenter_objects encodes count(I8) + items(I16 each)" do
      result = Encoder.encode({:carpenter_objects, %{items: [480, 163]}})
      expected =
        <<71::little-signed-16>> <>
        <<2::unsigned-integer-8>> <>
        <<480::little-signed-16>> <>
        <<163::little-signed-16>>
      assert result == expected
    end

    test "alquimista_objects encodes count(I16) + items(I16 each)" do
      result = Encoder.encode({:alquimista_objects, %{items: [37]}})
      expected =
        <<130::little-signed-16>> <>
        <<1::little-signed-16>> <>
        <<37::little-signed-16>>
      assert result == expected
    end

    test "sastre_objects encodes count(I16) + items(I16 each)" do
      result = Encoder.encode({:sastre_objects, %{items: [3578, 32]}})
      expected =
        <<132::little-signed-16>> <>
        <<2::little-signed-16>> <>
        <<3578::little-signed-16>> <>
        <<32::little-signed-16>>
      assert result == expected
    end

    test "empty item list encodes zero count" do
      result = Encoder.encode({:blacksmith_weapons, %{items: []}})
      expected = <<68::little-signed-16>> <> <<0::little-signed-16>>
      assert result == expected
    end
  end
end
