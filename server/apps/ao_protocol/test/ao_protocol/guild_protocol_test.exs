defmodule AoProtocol.GuildProtocolTest do
  @moduledoc """
  Golden byte tests for all guild-related packets.
  Covers all 27 client→server decoders and 7 server→client encoders.
  Verifies exact VB6 wire format parity and stream integrity.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder
  alias AoProtocol.Server.Encoder

  # ============================================================
  # Helper: build a raw client packet with Int16 packet ID prefix
  # ============================================================
  defp string8(str), do: <<byte_size(str)::little-signed-16, str::binary>>
  defp int8(v), do: <<v>>
  defp int16(v), do: <<v::little-signed-16>>
  defp int32(v), do: <<v::little-signed-32>>

  # ============================================================
  # Client → Server decoder golden tests (27 guild packets)
  # ============================================================

  describe "eCreateNewGuild (ID 3) decode" do
    test "decodes guild creation with all fields" do
      packet = int16(3) <> string8("A great clan") <> string8("Warriors") <> int8(2)
      assert {:ok, {:guild_create, params}, <<>>} = Decoder.decode(packet)
      assert params.description == "A great clan"
      assert params.name == "Warriors"
      assert params.alignment == 2
    end

    test "preserves trailing bytes" do
      packet = int16(3) <> string8("desc") <> string8("name") <> int8(0) <> <<0xFF>>
      assert {:ok, {:guild_create, _}, <<0xFF>>} = Decoder.decode(packet)
    end

    test "incomplete string returns :incomplete" do
      packet = int16(3) <> <<5::little-signed-16, "ab">>
      assert :incomplete = Decoder.decode(packet)
    end
  end

  describe "eGuildAcceptPeace (ID 17) decode" do
    test "decodes guild name" do
      packet = int16(17) <> string8("Enemigos")
      assert {:ok, {:guild_accept_peace, %{guild: "Enemigos"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildRejectAlliance (ID 18) decode" do
    test "decodes guild name" do
      packet = int16(18) <> string8("Aliados")
      assert {:ok, {:guild_reject_alliance, %{guild: "Aliados"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildRejectPeace (ID 19) decode" do
    test "decodes guild name" do
      packet = int16(19) <> string8("Rivales")
      assert {:ok, {:guild_reject_peace, %{guild: "Rivales"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildAcceptAlliance (ID 20) decode" do
    test "decodes guild name" do
      packet = int16(20) <> string8("Friends")
      assert {:ok, {:guild_accept_alliance, %{guild: "Friends"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildOfferPeace (ID 21) decode" do
    test "decodes guild name and proposal" do
      packet = int16(21) <> string8("WarGuild") <> string8("Let's end this")
      assert {:ok, {:guild_offer_peace, params}, <<>>} = Decoder.decode(packet)
      assert params.guild == "WarGuild"
      assert params.proposal == "Let's end this"
    end
  end

  describe "eGuildOfferAlliance (ID 22) decode" do
    test "decodes guild name and proposal" do
      packet = int16(22) <> string8("AllyGuild") <> string8("Unite!")
      assert {:ok, {:guild_offer_alliance, params}, <<>>} = Decoder.decode(packet)
      assert params.guild == "AllyGuild"
      assert params.proposal == "Unite!"
    end
  end

  describe "eGuildAllianceDetails (ID 23) decode" do
    test "decodes guild name" do
      packet = int16(23) <> string8("TargetGuild")
      assert {:ok, {:guild_alliance_details, %{guild: "TargetGuild"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildPeaceDetails (ID 24) decode" do
    test "decodes guild name" do
      packet = int16(24) <> string8("PeaceTarget")
      assert {:ok, {:guild_peace_details, %{guild: "PeaceTarget"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildRequestJoinerInfo (ID 25) decode" do
    test "decodes username" do
      packet = int16(25) <> string8("NewPlayer")
      assert {:ok, {:guild_request_joiner_info, %{username: "NewPlayer"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildAlliancePropList (ID 26) decode" do
    test "decodes with no payload" do
      packet = int16(26)
      assert {:ok, {:guild_alliance_prop_list, %{}}, <<>>} = Decoder.decode(packet)
    end

    test "preserves trailing bytes" do
      packet = int16(26) <> <<0xAB, 0xCD>>
      assert {:ok, {:guild_alliance_prop_list, %{}}, <<0xAB, 0xCD>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildPeacePropList (ID 27) decode" do
    test "decodes with no payload" do
      packet = int16(27)
      assert {:ok, {:guild_peace_prop_list, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildDeclareWar (ID 28) decode" do
    test "decodes guild name" do
      packet = int16(28) <> string8("Enemigos")
      assert {:ok, {:guild_declare_war, %{guild: "Enemigos"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildNewWebsite (ID 29) decode" do
    test "decodes website URL" do
      packet = int16(29) <> string8("http://clan.example.com")
      assert {:ok, {:guild_new_website, %{website: "http://clan.example.com"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildAcceptNewMember (ID 30) decode" do
    test "decodes username" do
      packet = int16(30) <> string8("Applicant")
      assert {:ok, {:guild_accept_new_member, %{username: "Applicant"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildRejectNewMember (ID 31) decode" do
    test "decodes username and reason" do
      packet = int16(31) <> string8("Rejected") <> string8("Too low level")
      assert {:ok, {:guild_reject_new_member, params}, <<>>} = Decoder.decode(packet)
      assert params.username == "Rejected"
      assert params.reason == "Too low level"
    end
  end

  describe "eGuildKickMember (ID 32) decode" do
    test "decodes username" do
      packet = int16(32) <> string8("Kicked")
      assert {:ok, {:guild_kick_member, %{username: "Kicked"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildUpdateNews (ID 33) decode" do
    test "decodes news text" do
      packet = int16(33) <> string8("War declared on Evil Clan!")
      assert {:ok, {:guild_update_news, %{news: "War declared on Evil Clan!"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildMemberInfo (ID 34) decode" do
    test "decodes username" do
      packet = int16(34) <> string8("SomePlayer")
      assert {:ok, {:guild_member_info, %{username: "SomePlayer"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildOpenElections (ID 35) decode" do
    test "decodes with no payload" do
      packet = int16(35)
      assert {:ok, {:guild_open_elections, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildRequestMembership (ID 36) decode" do
    test "decodes guild and application" do
      packet = int16(36) <> string8("TargetClan") <> string8("I want to join!")
      assert {:ok, {:guild_request_membership, params}, <<>>} = Decoder.decode(packet)
      assert params.guild == "TargetClan"
      assert params.application == "I want to join!"
    end
  end

  describe "eGuildRequestDetails (ID 37) decode" do
    test "decodes guild name" do
      packet = int16(37) <> string8("InfoClan")
      assert {:ok, {:guild_request_details, %{guild: "InfoClan"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildLeave (ID 40) decode" do
    test "decodes with no payload" do
      packet = int16(40)
      assert {:ok, {:guild_leave, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildMessage (ID 59) decode" do
    test "decodes chat message with packet counter" do
      packet = int16(59) <> string8("Hello clan!") <> int32(42)
      assert {:ok, {:guild_message, %{message: "Hello clan!"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildOnline (ID 60) decode" do
    test "decodes with no payload" do
      packet = int16(60)
      assert {:ok, {:guild_online, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eGuildVote (ID 65) decode" do
    test "decodes vote target" do
      packet = int16(65) <> string8("LeaderCandidate")
      assert {:ok, {:guild_vote, %{vote: "LeaderCandidate"}}, <<>>} = Decoder.decode(packet)
    end
  end

  describe "eRequestGuildLeaderInfo (ID 84) decode" do
    test "decodes with no payload" do
      packet = int16(84)
      assert {:ok, {:request_guild_leader_info, %{}}, <<>>} = Decoder.decode(packet)
    end
  end

  # ============================================================
  # Stream integrity: multi-packet and truncation tests
  # ============================================================

  describe "guild packet stream integrity" do
    test "two guild packets in sequence decode correctly" do
      pkt1 = int16(40)  # guild_leave (no payload)
      pkt2 = int16(28) <> string8("Enemy")  # guild_declare_war

      assert {:ok, {:guild_leave, %{}}, rest} = Decoder.decode(pkt1 <> pkt2)
      assert {:ok, {:guild_declare_war, %{guild: "Enemy"}}, <<>>} = Decoder.decode(rest)
    end

    test "truncated string8 field returns :incomplete" do
      # guild_declare_war with incomplete string
      packet = int16(28) <> <<10::little-signed-16, "abc">>
      assert :incomplete = Decoder.decode(packet)
    end

    test "single byte buffer returns :incomplete" do
      assert :incomplete = Decoder.decode(<<3>>)
    end

    test "empty buffer returns :incomplete" do
      assert :incomplete = Decoder.decode(<<>>)
    end
  end

  # ============================================================
  # Server → Client encoder golden tests (7 guild packets)
  # ============================================================

  describe "eGuildChat (ID 39) encode" do
    test "encodes status and message" do
      result = Encoder.encode({:guild_chat, %{status: 0, message: "Hello guild"}})
      <<39::little-signed-16, 0, len::little-signed-16, msg::binary-size(len)>> = result
      assert msg == "Hello guild"
    end
  end

  describe "eguildList (ID 56) encode" do
    test "encodes guild names string" do
      result = Encoder.encode({:guild_list, %{guild_names: "Clan1\nClan2\nClan3"}})
      <<56::little-signed-16, len::little-signed-16, names::binary-size(len)>> = result
      assert names == "Clan1\nClan2\nClan3"
    end
  end

  describe "eguildNews (ID 89) encode" do
    test "encodes all fields in correct order" do
      result = Encoder.encode({:guild_news, %{
        news: "Big news!",
        guild_list: "GuildA",
        member_list: "Player1,Player2",
        level: 3,
        current_exp: 150,
        needed_exp: 500
      }})

      <<89::little-signed-16, rest::binary>> = result

      # Parse fields in order: news(S8) + guild_list(S8) + member_list(S8) + level(I8) + exp(I16) + needed(I16)
      {:ok, news, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, guild_list, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, member_list, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, level, rest} = AoProtocol.Reader.read_int8(rest)
      {:ok, exp, rest} = AoProtocol.Reader.read_int16(rest)
      {:ok, needed, <<>>} = AoProtocol.Reader.read_int16(rest)

      assert news == "Big news!"
      assert guild_list == "GuildA"
      assert member_list == "Player1,Player2"
      assert level == 3
      assert exp == 150
      assert needed == 500
    end
  end

  describe "eGuildLeaderInfo (ID 94) encode" do
    test "encodes leader info with all fields" do
      result = Encoder.encode({:guild_leader_info, %{
        guild_list: "guilds",
        member_list: "members",
        news: "news text",
        requests: "req1,req2",
        level: 5,
        current_exp: 200,
        needed_exp: 1000
      }})

      <<94::little-signed-16, rest::binary>> = result

      {:ok, guild_list, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, member_list, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, news, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, requests, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, level, rest} = AoProtocol.Reader.read_int8(rest)
      {:ok, exp, rest} = AoProtocol.Reader.read_int16(rest)
      {:ok, needed, <<>>} = AoProtocol.Reader.read_int16(rest)

      assert guild_list == "guilds"
      assert member_list == "members"
      assert news == "news text"
      assert requests == "req1,req2"
      assert level == 5
      assert exp == 200
      assert needed == 1000
    end
  end

  describe "eGuildDetails (ID 95) encode" do
    test "encodes guild details" do
      result = Encoder.encode({:guild_details, %{
        name: "TestClan",
        founder: "FounderName",
        date: "2026-01-01",
        leader: "LeaderName",
        member_count: 15,
        alignment: "Real",
        description: "A mighty clan",
        level: 4
      }})

      <<95::little-signed-16, rest::binary>> = result

      {:ok, name, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, founder, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, date, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, leader, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, members, rest} = AoProtocol.Reader.read_int16(rest)
      {:ok, alignment, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, desc, rest} = AoProtocol.Reader.read_string8(rest)
      {:ok, level, <<>>} = AoProtocol.Reader.read_int8(rest)

      assert name == "TestClan"
      assert founder == "FounderName"
      assert date == "2026-01-01"
      assert leader == "LeaderName"
      assert members == 15
      assert alignment == "Real"
      assert desc == "A mighty clan"
      assert level == 4
    end
  end

  describe "eShowGuildFundationForm (ID 96) encode" do
    test "encodes empty payload" do
      result = Encoder.encode({:show_guild_fundation_form, %{}})
      assert result == <<96::little-signed-16>>
    end
  end

  describe "eGuildConfig (ID 201) encode" do
    test "encodes config bytes and members_by_level array" do
      result = Encoder.encode({:guild_config, %{
        level_call_support: 3,
        level_see_invisible: 5,
        level_safe: 2,
        level_show_hp_bar: 4,
        max_guild_level: 7,
        members_by_level: [10, 20, 30, 40, 50, 60, 70]
      }})

      <<201::little-signed-16, rest::binary>> = result
      <<3, 5, 2, 4, 7, 10, 20, 30, 40, 50, 60, 70>> = rest
    end
  end
end
