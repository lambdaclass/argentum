defmodule Arena.UserTierPacketTest do
  use ExUnit.Case, async: true

  alias AoEntities.PlayerEntity
  alias Arena.Map.Helpers

  test "character_create_packet includes tipo_usuario from user_tier" do
    entity = %PlayerEntity{
      char_id: 1,
      char_index: 1,
      name: "Legendary",
      x: 50,
      y: 50,
      user_tier: :legend
    }

    {:character_create, packet} = Helpers.character_create_packet(entity)

    assert packet.tipo_usuario == 3
  end

  test "character_create_packet defaults tipo_usuario to 0 for normal players" do
    entity = %PlayerEntity{char_id: 1, char_index: 1, name: "Normal", x: 50, y: 50}

    {:character_create, packet} = Helpers.character_create_packet(entity)

    assert packet.tipo_usuario == 0
  end
end
