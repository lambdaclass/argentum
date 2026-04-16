defmodule GameBackend.CharactersConversionTest do
  @moduledoc """
  Tests for PlayerEntity <-> DB conversion functions.
  Pure function tests — no database required.
  """
  use ExUnit.Case, async: true

  alias GameBackend.Characters
  alias AoEntities.PlayerEntity

  describe "from_entity/1" do
    test "includes name and account_id required by changeset" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "TestPlayer",
        account_id: "account_1",
        x: 50,
        y: 50,
        race: :human,
        class: :warrior,
        gender: :male,
        home_city: :ullathorpe
      }

      attrs = Characters.from_entity(entity)

      assert attrs[:name] == "TestPlayer",
             "from_entity must include :name (required by changeset)"

      assert attrs[:account_id] == "account_1",
             "from_entity must include :account_id (required by changeset)"
    end

    test "includes race, class, gender, and home_city" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "TestPlayer",
        account_id: "account_1",
        x: 50,
        y: 50,
        race: :elfo,
        class: :mago,
        gender: :female,
        home_city: :nix
      }

      attrs = Characters.from_entity(entity)

      assert attrs[:race] == "elfo"
      assert attrs[:class] == "mago"
      assert attrs[:gender] == "female"
      assert attrs[:home_city] == "nix"
    end

    test "roundtrips through to_entity and back preserving identity fields" do
      entity = %PlayerEntity{
        char_id: 42,
        name: "Roundtrip",
        account_id: "acct_42",
        x: 10,
        y: 20,
        heading: :north,
        race: :enano,
        class: :guerrero,
        gender: :male,
        home_city: :ullathorpe,
        hp: 80,
        max_hp: 100,
        body_id: 300,
        head_id: 5
      }

      attrs = Characters.from_entity(entity)

      # These must be present so Characters.create/changeset can work
      assert Map.has_key?(attrs, :name)
      assert Map.has_key?(attrs, :account_id)
      assert Map.has_key?(attrs, :race)
      assert Map.has_key?(attrs, :class)
      assert Map.has_key?(attrs, :gender)
      assert Map.has_key?(attrs, :home_city)
    end
  end
end
