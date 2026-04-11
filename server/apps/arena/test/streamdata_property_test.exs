defmodule Arena.StreamDataPropertyTest do
  @moduledoc """
  Property-based tests using StreamData / ExUnitProperties for combat formulas,
  character creation, and binary protocol round-trips.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arena.Combat
  alias Arena.CharacterCreation
  alias AoProtocol.Writer
  alias AoProtocol.Reader

  # Valid class IDs used in GameData (combat classes)
  @class_ids [1, 2, 3, 4, 5, 6]

  # Valid head ranges per {race_id, gender_id}
  @head_ranges %{
    {1, 1} => [{1, 41}, {778, 791}],
    {2, 1} => [{101, 132}, {531, 545}],
    {3, 1} => [{200, 229}, {792, 810}],
    {4, 1} => [{300, 344}],
    {5, 1} => [{400, 429}],
    {6, 1} => [{500, 529}],
    {1, 2} => [{50, 80}, {187, 190}, {230, 246}],
    {2, 2} => [{150, 179}, {758, 777}],
    {3, 2} => [{250, 279}],
    {4, 2} => [{350, 379}],
    {5, 2} => [{450, 479}],
    {6, 2} => [{550, 579}]
  }

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---- Generators ----

  defp class_id_gen, do: member_of(@class_ids)

  defp skill_gen, do: integer(1..100)
  defp stat_gen, do: integer(1..50)
  defp level_gen, do: integer(1..50)

  defp valid_creation_params_gen do
    gen all(
          race <- integer(1..6),
          gender <- integer(1..2),
          class <- integer(1..12),
          city <- integer(1..9),
          suffix <- integer(1..99999)
        ) do
      head = pick_valid_head(race, gender)

      %{
        name: "TestChar#{suffix}",
        race: race,
        gender: gender,
        class: class,
        head: head,
        home_city: city,
        account_id: "acc_#{suffix}"
      }
    end
  end

  defp pick_valid_head(race, gender) do
    ranges = Map.fetch!(@head_ranges, {race, gender})
    {lo, hi} = Enum.random(ranges)
    Enum.random(lo..hi)
  end

  # =========================================================================
  # Combat formula properties
  # =========================================================================

  describe "combat: hit_chance/8" do
    property "always returns a value in 5..95" do
      check all(
              atk_skill <- skill_gen(),
              atk_agi <- stat_gen(),
              atk_level <- level_gen(),
              atk_class <- class_id_gen(),
              def_tactics <- skill_gen(),
              def_agi <- stat_gen(),
              def_level <- level_gen(),
              def_class <- class_id_gen()
            ) do
        result =
          Combat.hit_chance(
            atk_skill,
            atk_agi,
            atk_level,
            atk_class,
            def_tactics,
            def_agi,
            def_level,
            def_class
          )

        assert result >= 5 and result <= 95,
               "hit_chance returned #{result}, expected 5..95"
      end
    end

    property "monotonically increases with weapon skill (on average)" do
      # Higher atk_skill should give >= hit chance for same defender stats
      check all(
              low_skill <- integer(1..40),
              high_skill <- integer(60..100),
              agi <- stat_gen(),
              level <- level_gen(),
              atk_class <- class_id_gen(),
              def_tactics <- skill_gen(),
              def_agi <- stat_gen(),
              def_level <- level_gen(),
              def_class <- class_id_gen()
            ) do
        low_hit =
          Combat.hit_chance(low_skill, agi, level, atk_class, def_tactics, def_agi, def_level, def_class)

        high_hit =
          Combat.hit_chance(high_skill, agi, level, atk_class, def_tactics, def_agi, def_level, def_class)

        assert high_hit >= low_hit,
               "higher skill (#{high_skill}->#{high_hit}) should >= lower skill (#{low_skill}->#{low_hit})"
      end
    end
  end

  describe "combat: melee_damage/4" do
    property "always returns >= 1" do
      check all(
              weapon_min <- integer(0..100),
              weapon_max_extra <- integer(0..100),
              str <- stat_gen(),
              class <- class_id_gen()
            ) do
        weapon_max = weapon_min + weapon_max_extra
        result = Combat.melee_damage(weapon_min, weapon_max, str, class)
        assert result >= 1, "melee_damage returned #{result}, expected >= 1"
      end
    end

    property "monotonically increases with strength modifier (on average over many samples)" do
      # We compare averages: higher str should yield higher average damage
      check all(
              weapon_min <- integer(16..30),
              weapon_max_extra <- integer(5..20),
              class <- class_id_gen(),
              max_initial_options: [max_runs: 30]
            ) do
        weapon_max = weapon_min + weapon_max_extra
        n = 200

        avg_low =
          Enum.reduce(1..n, 0, fn _, acc ->
            acc + Combat.melee_damage(weapon_min, weapon_max, 16, class)
          end) / n

        avg_high =
          Enum.reduce(1..n, 0, fn _, acc ->
            acc + Combat.melee_damage(weapon_min, weapon_max, 50, class)
          end) / n

        assert avg_high >= avg_low,
               "avg damage with str=50 (#{avg_high}) should >= str=16 (#{avg_low})"
      end
    end
  end

  describe "combat: xp_gain/5" do
    property "always returns >= 0" do
      check all(
              damage <- integer(0..500),
              give_exp <- integer(0..500),
              max_hp <- integer(1..500),
              player_level <- level_gen(),
              npc_level <- level_gen()
            ) do
        result = Combat.xp_gain(damage, give_exp, max_hp, player_level, npc_level)
        assert result >= 0, "xp_gain returned #{result}, expected >= 0"
      end
    end
  end

  # =========================================================================
  # Character creation properties
  # =========================================================================

  describe "character creation: valid params always succeed" do
    property "create/1 with valid params returns {:ok, entity} with positive HP and mana >= 0" do
      check all(params <- valid_creation_params_gen()) do
        result = CharacterCreation.create(params)
        assert {:ok, entity} = result, "create failed for #{inspect(params)}: #{inspect(result)}"
        assert entity.hp > 0, "HP should be > 0, got #{entity.hp}"
        assert entity.mana >= 0, "Mana should be >= 0, got #{entity.mana}"
        assert entity.max_hp > 0
        assert entity.level == 1
        assert entity.xp == 0
      end
    end

    property "stats sum is bounded (5 stats between 13 and 23 each, so sum in 65..115)" do
      check all(params <- valid_creation_params_gen()) do
        {:ok, entity} = CharacterCreation.create(params)
        total = entity.str + entity.agi + entity.int + entity.con + entity.cha

        assert total >= 65 and total <= 115,
               "stats sum #{total} out of expected range 65..115"

        for {name, val} <- [str: entity.str, agi: entity.agi, int: entity.int, con: entity.con, cha: entity.cha] do
          assert val >= 13 and val <= 23,
                 "#{name} = #{val}, expected 13..23"
        end
      end
    end
  end

  # =========================================================================
  # Binary protocol round-trip properties
  # =========================================================================

  describe "protocol round-trip: int8" do
    property "write_int8 -> read_int8 round-trips for any 0..255" do
      check all(value <- integer(0..255)) do
        bin = Writer.write_int8(value)
        assert {:ok, ^value, <<>>} = Reader.read_int8(bin)
      end
    end
  end

  describe "protocol round-trip: int16" do
    property "write_int16 -> read_int16 round-trips for any -32768..32767" do
      check all(value <- integer(-32_768..32_767)) do
        bin = Writer.write_int16(value)
        assert {:ok, ^value, <<>>} = Reader.read_int16(bin)
      end
    end
  end

  describe "protocol round-trip: int32" do
    property "write_int32 -> read_int32 round-trips for any int32" do
      check all(value <- integer(-2_147_483_648..2_147_483_647)) do
        bin = Writer.write_int32(value)
        assert {:ok, ^value, <<>>} = Reader.read_int32(bin)
      end
    end
  end

  describe "protocol round-trip: string8" do
    property "write_string8 -> read_string8 round-trips for any printable ASCII string" do
      check all(str <- string(:printable, min_length: 0, max_length: 200)) do
        bin = Writer.write_string8(str)
        assert {:ok, ^str, <<>>} = Reader.read_string8(bin)
      end
    end
  end

  describe "protocol round-trip: real32" do
    property "write_real32 -> read_real32 approximately round-trips (within float tolerance)" do
      check all(value <- float(min: -1.0e10, max: 1.0e10)) do
        bin = Writer.write_real32(value)
        {:ok, result, <<>>} = Reader.read_real32(bin)

        # Float32 has limited precision; check relative tolerance
        if abs(value) < 1.0e-6 do
          assert abs(result) < 1.0e-2,
                 "near-zero value #{value} round-tripped to #{result}"
        else
          relative_error = abs(result - value) / abs(value)

          assert relative_error < 1.0e-3,
                 "value #{value} round-tripped to #{result}, relative error #{relative_error}"
        end
      end
    end
  end

  describe "protocol round-trip: bool" do
    property "write_bool -> read_bool round-trips" do
      check all(value <- boolean()) do
        bin = Writer.write_bool(value)
        assert {:ok, ^value, <<>>} = Reader.read_bool(bin)
      end
    end
  end
end
