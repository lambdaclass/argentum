defmodule AoProtocol.PartyClanSnapshotTest do
  @moduledoc """
  Tests for party (datos_grupo) and guild snapshot packet encoding.
  Verifies VB6 wire format parity for WriteDatosGrupo, WriteGuildNews, WriteGuildDetails.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Server.Encoder

  # ============================================================
  # Party snapshot (eDatosGrupo, ID 143)
  # ============================================================

  describe "eDatosGrupo (ID 143) encode — not in party" do
    test "encodes en_grupo=false with no member data" do
      result = Encoder.encode({:datos_grupo, %{en_grupo: false, members: []}})
      assert result == <<143::little-signed-16, 0>>
    end
  end

  describe "eDatosGrupo (ID 143) encode — in party with members" do
    test "encodes leader marked with (Lider) suffix" do
      result =
        Encoder.encode(
          {:datos_grupo,
           %{
             en_grupo: true,
             members: ["Hero", "Warrior", "Mage"],
             leader_index: 0
           }}
        )

      <<143::little-signed-16, 1, count, rest::binary>> = result
      assert count == 3

      # First member is leader, gets "(Lider)" suffix
      {:ok, name1, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, name2, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, name3, <<>>} = AoProtocol.Reader.read_string8(rest)

      assert name1 == "Hero(Lider)"
      assert name2 == "Warrior"
      assert name3 == "Mage"
    end

    test "single member party (leader alone)" do
      result =
        Encoder.encode(
          {:datos_grupo,
           %{
             en_grupo: true,
             members: ["Solo"],
             leader_index: 0
           }}
        )

      <<143::little-signed-16, 1, 1, rest::binary>> = result
      {:ok, name, <<>>} = AoProtocol.Reader.read_string8(rest)
      assert name == "Solo(Lider)"
    end

    test "leader_index defaults to 0 when not provided" do
      result =
        Encoder.encode(
          {:datos_grupo,
           %{
             en_grupo: true,
             members: ["Alpha", "Beta"]
           }}
        )

      <<143::little-signed-16, 1, 2, rest::binary>> = result
      {:ok, name1, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, name2, <<>>} = AoProtocol.Reader.read_string8(rest)

      assert name1 == "Alpha(Lider)"
      assert name2 == "Beta"
    end
  end

  # ============================================================
  # Guild details (eGuildDetails, ID 95) — already existed but
  # we verify the full snapshot round-trip here
  # ============================================================

  describe "eGuildDetails (ID 95) encode — full snapshot" do
    test "encodes all guild detail fields" do
      result =
        Encoder.encode(
          {:guild_details,
           %{
             name: "LosGuerreros",
             founder: "Fundador",
             date: "2025-06-15",
             leader: "Comandante",
             member_count: 25,
             alignment: "Real",
             description: "Un clan poderoso",
             level: 5
           }}
        )

      <<95::little-signed-16, rest::binary>> = result

      {:ok, name, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, founder, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, date, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, leader, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, member_count, rest} = AoProtocol.Reader.read_int16(rest)
      {:ok, alignment, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, desc, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, level, <<>>} = AoProtocol.Reader.read_int8(rest)

      assert name == "LosGuerreros"
      assert founder == "Fundador"
      assert date == "2025-06-15"
      assert leader == "Comandante"
      assert member_count == 25
      assert alignment == "Real"
      assert desc == "Un clan poderoso"
      assert level == 5
    end
  end

  # ============================================================
  # Guild news (eguildNews, ID 89) — already existed but we
  # verify the full snapshot round-trip here
  # ============================================================

  describe "eguildNews (ID 89) encode — full snapshot" do
    test "encodes all guild news fields" do
      result =
        Encoder.encode(
          {:guild_news,
           %{
             news: "Guerra declarada!",
             guild_list: "ClanA\nClanB",
             member_list: "Player1,Player2,Player3",
             level: 7,
             current_exp: 3500,
             needed_exp: 10000
           }}
        )

      <<89::little-signed-16, rest::binary>> = result

      {:ok, news, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, guild_list, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, member_list, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, level, rest} = AoProtocol.Reader.read_int8(rest)
      {:ok, exp, rest} = AoProtocol.Reader.read_int16(rest)
      {:ok, needed, <<>>} = AoProtocol.Reader.read_int16(rest)

      assert news == "Guerra declarada!"
      assert guild_list == "ClanA\nClanB"
      assert member_list == "Player1,Player2,Player3"
      assert level == 7
      assert exp == 3500
      assert needed == 10000
    end
  end
end
