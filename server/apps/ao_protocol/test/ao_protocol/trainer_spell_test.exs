defmodule AoProtocol.TrainerSpellTest do
  @moduledoc """
  Tests for trainer creature list and spell info packet encoding — task 32.
  Verifies VB6 wire format parity for eTrainerCreatureList (ID 104)
  and eSpellInfo (ID 105).
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Server.Encoder
  alias AoProtocol.Reader

  # ============================================================
  # Trainer creature list (eTrainerCreatureList, ID 104)
  # ============================================================

  describe "eTrainerCreatureList (ID 104) encode" do
    test "encodes single creature name" do
      result = Encoder.encode({:trainer_creature_list, %{creature_names: ["Lobo"]}})

      <<104::little-signed-16, rest::binary>> = result
      {:ok, names_str, <<>>} = Reader.read_string8(rest)
      assert names_str == "Lobo"
    end

    test "encodes multiple creature names comma-separated" do
      result =
        Encoder.encode(
          {:trainer_creature_list,
           %{creature_names: ["Lobo", "Oso Pardo", "Dragon Negro"]}}
        )

      <<104::little-signed-16, rest::binary>> = result
      {:ok, names_str, <<>>} = Reader.read_string8(rest)
      assert names_str == "Lobo,Oso Pardo,Dragon Negro"

      names = String.split(names_str, ",")
      assert length(names) == 3
      assert Enum.at(names, 0) == "Lobo"
      assert Enum.at(names, 2) == "Dragon Negro"
    end

    test "encodes empty creature list as empty string" do
      result = Encoder.encode({:trainer_creature_list, %{creature_names: []}})

      <<104::little-signed-16, rest::binary>> = result
      {:ok, names_str, <<>>} = Reader.read_string8(rest)
      assert names_str == ""
    end
  end

  # ============================================================
  # Spell info (eSpellInfo, ID 105)
  # ============================================================

  describe "eSpellInfo (ID 105) encode" do
    test "encodes all spell info fields" do
      result =
        Encoder.encode(
          {:spell_info,
           %{
             name: "Apocalipsis",
             desc: "Destruye todo a tu alrededor",
             skill_required: 95,
             mana: 800
           }}
        )

      <<105::little-signed-16, rest::binary>> = result

      {:ok, name, rest} = Reader.read_string8(rest)
      {:ok, desc, rest} = Reader.read_string8(rest)
      {:ok, skill, rest} = Reader.read_int16(rest)
      {:ok, mana, <<>>} = Reader.read_int16(rest)

      assert name == "Apocalipsis"
      assert desc == "Destruye todo a tu alrededor"
      assert skill == 95
      assert mana == 800
    end

    test "encodes low-level spell with zero skill requirement" do
      result =
        Encoder.encode(
          {:spell_info,
           %{
             name: "Curar Heridas Menores",
             desc: "Cura una pequena cantidad de HP",
             skill_required: 0,
             mana: 10
           }}
        )

      <<105::little-signed-16, rest::binary>> = result

      {:ok, name, rest} = Reader.read_string8(rest)
      {:ok, desc, rest} = Reader.read_string8(rest)
      {:ok, skill, rest} = Reader.read_int16(rest)
      {:ok, mana, <<>>} = Reader.read_int16(rest)

      assert name == "Curar Heridas Menores"
      assert desc == "Cura una pequena cantidad de HP"
      assert skill == 0
      assert mana == 10
    end
  end

  # ============================================================
  # Show forum form (eShowForumForm, ID 202)
  # ============================================================

  describe "eShowForumForm (ID 202) encode" do
    test "encodes forum with messages" do
      messages = [
        %{author: "Gandalf", title: "Bienvenidos", body: "Este es el foro principal."},
        %{author: "Aragorn", title: "Busco grupo", body: "Para ir a minas de Moria."}
      ]

      result =
        Encoder.encode({:show_forum_form, %{forum_id: 5, messages: messages}})

      <<202::little-signed-16, rest::binary>> = result

      {:ok, forum_id, rest} = Reader.read_int16(rest)
      {:ok, count, rest} = Reader.read_int16(rest)

      assert forum_id == 5
      assert count == 2

      {:ok, author1, rest} = Reader.read_string8(rest)
      {:ok, title1, rest} = Reader.read_string8(rest)
      {:ok, body1, rest} = Reader.read_string8(rest)

      {:ok, author2, rest} = Reader.read_string8(rest)
      {:ok, title2, rest} = Reader.read_string8(rest)
      {:ok, body2, <<>>} = Reader.read_string8(rest)

      assert author1 == "Gandalf"
      assert title1 == "Bienvenidos"
      assert body1 == "Este es el foro principal."
      assert author2 == "Aragorn"
      assert title2 == "Busco grupo"
      assert body2 == "Para ir a minas de Moria."
    end

    test "encodes empty forum" do
      result =
        Encoder.encode({:show_forum_form, %{forum_id: 10, messages: []}})

      <<202::little-signed-16, rest::binary>> = result

      {:ok, forum_id, rest} = Reader.read_int16(rest)
      {:ok, count, <<>>} = Reader.read_int16(rest)

      assert forum_id == 10
      assert count == 0
    end
  end
end
