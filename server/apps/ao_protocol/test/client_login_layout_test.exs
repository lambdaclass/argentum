defmodule AoProtocol.ClientLoginLayoutTest do
  @moduledoc """
  Cross-language fixture for the two login packets.

  The Rust client encodes login in `client-rs/crates/ao-core/src/protocol.rs`.
  Nothing in either build makes the two implementations agree, and the last
  disagreement was expensive: the client labelled packet 74 as
  existing-character login, sent the create-a-character packet on every
  connect, and reported "socket opened, bytes sent" as a successful session.

  These are the exact bytes `ao-core` emits, asserted against the server's own
  decoder. The identical arrays appear in that file's
  `login_bytes_match_the_shared_cross_language_fixture` test. Changing one
  encoder without the other fails here.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder

  # encode_login_new_char("Bot_1", "tok", "hash", NewCharacter::default())
  @new_char_fixture <<74, 0>> <>
                      <<3, 0>> <>
                      "tok" <>
                      <<5, 0>> <>
                      "Bot_1" <>
                      <<1, 0, 0>> <>
                      <<4, 0>> <>
                      "hash" <>
                      <<1, 1, 6>> <>
                      <<1, 0>> <>
                      <<1>>

  # encode_login_existing_char("session", 4242, "hash")
  @existing_char_fixture <<73, 0>> <>
                           <<7, 0>> <>
                           "session" <>
                           <<0x92, 0x10, 0, 0>> <>
                           <<1, 0, 0>> <>
                           <<4, 0>> <>
                           "hash"

  test "the Rust client's new-character login decodes with the creation choices intact" do
    assert {:ok, {:login_new_char, fields}, ""} = Decoder.decode(@new_char_fixture)

    assert fields.username == "Bot_1"
    assert fields.md5 == "hash"
    assert fields.version == "1.0.0"
    # These are the fields an earlier port treated as ignorable padding.
    assert fields.race == 1
    assert fields.gender == 1
    assert fields.class == 6
    assert fields.head == 1
    assert fields.home_city == 1
  end

  test "the Rust client's existing-character login decodes to a character id" do
    assert {:ok, {:login_existing_char, fields}, ""} = Decoder.decode(@existing_char_fixture)

    assert fields.session_token == "session"
    assert fields.char_id == 4242
    assert fields.version == "1.0.0"
    assert fields.md5 == "hash"
  end

  test "the two packets are distinct operations, not one with reordered fields" do
    assert {:ok, {:login_new_char, _}, ""} = Decoder.decode(@new_char_fixture)
    assert {:ok, {:login_existing_char, _}, ""} = Decoder.decode(@existing_char_fixture)
    refute @new_char_fixture == @existing_char_fixture
  end

  test "a fixture truncated anywhere asks for more data instead of decoding garbage" do
    for fixture <- [@new_char_fixture, @existing_char_fixture],
        width <- 2..(byte_size(fixture) - 1) do
      assert Decoder.decode(:binary.part(fixture, 0, width)) == :incomplete,
             "width #{width} should be incomplete"
    end
  end
end
