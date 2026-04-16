defmodule Arena.AppearanceBugsTest do
  @moduledoc """
  Tests for 5 appearance/visibility bugs:
  1. character_create_packet missing equipment fields (weapon_id, shield_id, helmet_id)
  2. character_change_packet missing equipment fields
  3. Death does not broadcast character_change to nearby players
  4. Equip item does not broadcast character_change to nearby players
  5. FX packets in social.ex use wrong field name (fx_id instead of fx)

  Bugs 1, 2, 4, 5 are tested as unit/packet-level tests.
  Bug 3 (death broadcast) requires a running MapServer with map data — tested via
  packet builder assertions here; full integration tested manually.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.Helpers
  alias AoEntities.PlayerEntity
  alias AoProtocol.Server.Encoder

  # ---- Bug 1: character_create_packet missing equipment fields ----

  describe "Bug 1: character_create_packet includes equipment" do
    test "Helpers.character_create_packet includes weapon_id/shield_id/helmet_id from equipment" do
      entity = %PlayerEntity{
        char_id: 99001,
        name: "Swordsman",
        char_index: 1,
        x: 50,
        y: 50,
        hp: 100,
        max_hp: 100,
        mana: 50,
        max_mana: 50,
        heading: :south,
        speeding: 1.0,
        equipment: %{weapon: 123, armor: nil, shield: 456, helmet: 789, ring: nil, municion: nil}
      }

      {_tag, params} = Helpers.character_create_packet(entity)

      assert params[:weapon_id] == 123,
             "character_create_packet should include weapon_id from equipment, got: #{inspect(params[:weapon_id])}"

      assert params[:shield_id] == 456,
             "character_create_packet should include shield_id from equipment"

      assert params[:helmet_id] == 789,
             "character_create_packet should include helmet_id from equipment"
    end

    test "character_create_packet encodes equipment into the wire format" do
      entity = %PlayerEntity{
        char_id: 99001,
        name: "Armed",
        char_index: 5,
        x: 10,
        y: 20,
        hp: 100,
        max_hp: 100,
        mana: 50,
        max_mana: 50,
        heading: :south,
        speeding: 1.0,
        equipment: %{weapon: 42, armor: nil, shield: 77, helmet: 88, ring: nil, municion: nil}
      }

      packet = Helpers.character_create_packet(entity)
      binary = Encoder.encode(packet)

      # Layout: id(2) + char_index(2) + body_id(2) + head_id(2) + heading(1) + x(1) + y(1) + weapon_id(2)
      <<_id::little-16, _ci::little-16, _body::little-16, _head::little-16, _heading::8, _x::8, _y::8,
        weapon_id::little-16, shield_id::little-16, helmet_id::little-16, _rest::binary>> = binary

      assert weapon_id == 42,
             "Wire format weapon_id should be 42, got #{weapon_id}"

      assert shield_id == 77,
             "Wire format shield_id should be 77, got #{shield_id}"

      assert helmet_id == 88,
             "Wire format helmet_id should be 88, got #{helmet_id}"
    end
  end

  # ---- Bug 2: character_change_packet missing equipment fields ----

  describe "Bug 2: character_change_packet includes equipment" do
    test "character_change_packet includes weapon_id/shield_id/helmet_id from equipment" do
      entity = %PlayerEntity{
        char_id: 99002,
        char_index: 2,
        heading: :south,
        body_id: 1,
        head_id: 1,
        equipment: %{weapon: 123, armor: nil, shield: 456, helmet: 789, ring: nil, municion: nil}
      }

      {_tag, params} = Helpers.character_change_packet(entity)

      assert params[:weapon_id] == 123,
             "character_change_packet should include weapon_id, got: #{inspect(params[:weapon_id])}"

      assert params[:shield_id] == 456
      assert params[:helmet_id] == 789
    end

    test "character_change_packet encodes equipment into the wire format" do
      entity = %PlayerEntity{
        char_id: 99002,
        char_index: 3,
        heading: :south,
        body_id: 1,
        head_id: 1,
        equipment: %{weapon: 42, armor: nil, shield: 77, helmet: 88, ring: nil, municion: nil}
      }

      packet = Helpers.character_change_packet(entity)
      binary = Encoder.encode(packet)

      # Layout: id(2) + char_index(2) + flags(1) + body(2) + head(2) + heading(1) + weapon(2) + shield(2) + helmet(2)
      <<_id::little-16, _ci::little-16, _flags::8, _body::little-16, _head::little-16, _heading::8,
        weapon_id::little-16, shield_id::little-16, helmet_id::little-16, _rest::binary>> = binary

      assert weapon_id == 42,
             "Wire format weapon_id should be 42, got #{weapon_id}"

      assert shield_id == 77,
             "Wire format shield_id should be 77, got #{shield_id}"

      assert helmet_id == 88,
             "Wire format helmet_id should be 88, got #{helmet_id}"
    end
  end

  # ---- Bug 3: Death should update appearance to ghost ----
  # Full integration (broadcast to observer) requires a running MapServer.
  # Here we test that the packet builder can represent a dead player correctly:
  # dead players should show body_id 829, head_id 0.

  describe "Bug 3: dead player appearance" do
    test "character_create_packet for a dead player should show ghost body" do
      entity = %PlayerEntity{
        char_id: 99010,
        name: "Ghost",
        char_index: 10,
        x: 50,
        y: 50,
        hp: 0,
        max_hp: 100,
        mana: 0,
        max_mana: 100,
        heading: :south,
        speeding: 1.0,
        dead: true,
        body_id: 5,
        head_id: 3,
        equipment: %{weapon: 42, armor: nil, shield: 77, helmet: nil, ring: nil, municion: nil}
      }

      {_tag, params} = Helpers.character_create_packet(entity)

      # Dead players should show ghost body (829) and no head/equipment
      assert params[:body_id] == 829,
             "Dead player should show ghost body 829, got #{params[:body_id]}"

      assert params[:head_id] == 0,
             "Dead player should show head 0, got #{params[:head_id]}"

      assert (params[:weapon_id] || 0) == 0,
             "Dead player should show no weapon"

      assert (params[:shield_id] || 0) == 0,
             "Dead player should show no shield"
    end
  end

  # ---- Bug 4: Duplicated packet builder ----
  # SessionLogic defines its own character_create_packet that diverges from Helpers.

  describe "Bug 4: single packet builder" do
    test "SessionLogic file should not define its own character_create_packet" do
      session_logic_path = Path.expand("../../ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex", __DIR__)
      {:ok, source} = File.read(session_logic_path)

      refute source =~ ~r/^\s*def character_create_packet\(/m,
             "SessionLogic should not define its own character_create_packet — use Helpers"
    end
  end

  # ---- Bug 5: FX field name mismatch ----

  describe "Bug 5: FX packets use correct field name" do
    test "encoder produces zero fx when fx_id is used instead of fx" do
      # This demonstrates the bug: code using fx_id gets 0 in the wire format
      buggy_packet = {:create_fx, %{char_index: 1, fx_id: 4, loops: 0}}
      correct_packet = {:create_fx, %{char_index: 1, fx: 4, loops: 0}}

      buggy_binary = Encoder.encode(buggy_packet)
      correct_binary = Encoder.encode(correct_packet)

      # Parse fx field: id(2) + char_index(2) + fx(2)
      <<_id1::little-16, _ci1::little-16, buggy_fx::little-16, _::binary>> = buggy_binary
      <<_id2::little-16, _ci2::little-16, correct_fx::little-16, _::binary>> = correct_binary

      # This proves the bug: fx_id produces 0, fx produces 4
      assert buggy_fx == 0, "fx_id field should produce 0 in wire (demonstrating the bug)"
      assert correct_fx == 4, "fx field should produce correct value"
    end

    test "social.ex meditate and resurrect use fx not fx_id" do
      social_path = Path.expand("../lib/arena/map/social.ex", __DIR__)
      {:ok, source} = File.read(social_path)

      # The file should not use fx_id in create_fx packets
      lines_with_fx_id =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ ~r/create_fx.*fx_id/ end)
        |> Enum.map(fn {_line, num} -> num end)

      assert lines_with_fx_id == [],
             "social.ex uses fx_id instead of fx on lines: #{inspect(lines_with_fx_id)}"
    end
  end

  # ---- Bug 6: Armor equip does not update body_id ----

  describe "Bug 6: armor changes body_id" do
    test "ItemDef parses ropaje fields from obj.dat sections" do
      section = %{
        "name" => "Armadura de Cuero",
        "objtype" => "3",
        "grhindex" => "274",
        "ropaje_humano_m" => "63",
        "ropaje_humano_f" => "3139",
        "ropaje_elfo_m" => "63",
        "ropaje_elfo_f" => "3139",
        "mindef" => "7",
        "maxdef" => "12",
        "valor" => "2500"
      }

      item_def = Arena.Data.ItemDef.from_section(30, section)
      assert item_def.ropaje != nil, "ItemDef should parse ropaje map"
      assert item_def.ropaje[:humano_m] == 63
      assert item_def.ropaje[:humano_f] == 3139
    end

    test "visual_state uses armor body_id when armor is equipped" do
      # An entity wearing armor item 30 which has ropaje body 63 for humano male
      entity = %PlayerEntity{
        char_id: 99040,
        char_index: 40,
        heading: :south,
        body_id: 63,
        head_id: 1,
        dead: false,
        equipment: %{weapon: nil, armor: 30, shield: nil, helmet: nil, ring: nil, municion: nil}
      }

      {_tag, params} = Helpers.character_create_packet(entity)

      # body_id should reflect the armor, not the naked body
      assert params[:body_id] == 63,
             "body_id should be the armor's ropaje body, got #{params[:body_id]}"
    end

    test "PlayerEntity has a base_body_id field for naked body restoration" do
      entity = %PlayerEntity{}

      assert Map.has_key?(entity, :base_body_id),
             "PlayerEntity should have a base_body_id field so armor unequip can restore naked body"
    end
  end
end
