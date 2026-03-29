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
  alias AoProtocol.Writer
  alias AoProtocol.Reader

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
    # VB6: WriteInt16(75) + WriteString8(message)
    test "decodes talk message" do
      msg = "Hello!"
      packet = <<75::little-signed-16, 6::little-signed-16, msg::binary>>
      assert {:ok, {:talk, %{message: "Hello!"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eAttack (ID 80) decode" do
    # VB6: WriteInt16(80) — no payload
    test "decodes attack" do
      packet = <<80::little-signed-16>>
      assert {:ok, {:attack, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eCastSpell (ID 94) decode" do
    # VB6: WriteInt16(94) + WriteInt8(SpellSlot)
    test "decodes cast spell" do
      packet = <<94::little-signed-16, 3>>
      assert {:ok, {:cast_spell, %{spell_slot: 3}}, <<>>} = Decoder.decode(packet)
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
      packet = <<75::little-signed-16, 2::little-signed-16, msg::binary>> <> extra
      assert {:ok, {:talk, %{message: "Hi"}}, ^extra} = Decoder.decode(packet)
    end
  end

  # ============================================================
  # Multi-packet buffer decode test
  # ============================================================

  describe "multiple packets in buffer" do
    test "decodes first packet and preserves rest" do
      talk1 = <<75::little-signed-16, 2::little-signed-16, "Hi">>
      talk2 = <<75::little-signed-16, 5::little-signed-16, "World">>
      buffer = talk1 <> talk2

      assert {:ok, {:talk, %{message: "Hi"}}, rest} = Decoder.decode(buffer)
      assert {:ok, {:talk, %{message: "World"}}, <<>>} = Decoder.decode(rest)
    end
  end
end
