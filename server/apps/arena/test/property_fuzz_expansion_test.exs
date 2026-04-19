defmodule Arena.PropertyFuzzExpansionTest do
  @moduledoc """
  Randomized coverage and fuzz tests for combat formulas, character creation,
  and binary protocol parsing.

  Uses randomized ExUnit loops (not property-testing generators/shrinking)
  to exercise invariants across many random inputs. Covers composition
  invariants, extreme/boundary values, character creation constraints,
  and binary protocol fuzzing.
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.CharacterCreation
  alias AoProtocol.Reader

  @iterations 1000

  # Valid class IDs used in GameData (combat classes)
  @class_ids [1, 2, 3, 4, 5, 6]

  # Full class range for character creation
  @creation_classes 1..12
  @races 1..6
  @genders 1..2
  @cities 1..9

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

  defp rand_class, do: Enum.random(@class_ids)
  defp rand_skill, do: :rand.uniform(100)
  defp rand_stat, do: :rand.uniform(50)
  defp rand_level, do: :rand.uniform(50)
  defp rand_damage, do: :rand.uniform(200)
  defp rand_pct, do: :rand.uniform(100)

  defp rand_valid_head(race, gender) do
    ranges = Map.fetch!(@head_ranges, {race, gender})
    {lo, hi} = Enum.random(ranges)
    Enum.random(lo..hi)
  end

  defp valid_creation_params do
    race = Enum.random(Enum.to_list(@races))
    gender = Enum.random(Enum.to_list(@genders))

    %{
      name: "TestChar#{:rand.uniform(99999)}",
      race: race,
      gender: gender,
      class: Enum.random(Enum.to_list(@creation_classes)),
      head: rand_valid_head(race, gender),
      home_city: Enum.random(Enum.to_list(@cities)),
      account_id: "acc_#{:rand.uniform(99999)}"
    }
  end

  # ===========================================================================
  # Combat composition invariants
  # ===========================================================================

  describe "combat composition: melee_damage -> apply_defense always >= 0" do
    test "#{@iterations} random pipelines" do
      for _ <- 1..@iterations do
        min_w = :rand.uniform(30)
        max_w = min_w + :rand.uniform(20)
        str = rand_stat()
        class = rand_class()

        raw = Combat.melee_damage(min_w, max_w, str, class)

        min_def = :rand.uniform(100) - 1
        max_def = min_def + :rand.uniform(50)
        {dmg, loc} = Combat.apply_defense(raw, {min_def, max_def})

        assert dmg >= 0,
               "melee->defense pipeline produced #{dmg}, expected >= 0"

        assert loc in [:head, :body]
      end
    end
  end

  describe "combat composition: melee_damage -> apply_critical -> apply_defense always >= 0" do
    test "#{@iterations} random pipelines with critical" do
      for _ <- 1..@iterations do
        min_w = :rand.uniform(30)
        max_w = min_w + :rand.uniform(20)
        str = rand_stat()
        class = rand_class()

        raw = Combat.melee_damage(min_w, max_w, str, class)
        critted = Combat.apply_critical(raw)

        min_def = :rand.uniform(100) - 1
        max_def = min_def + :rand.uniform(50)
        {dmg, loc} = Combat.apply_defense(critted, {min_def, max_def})

        assert dmg >= 0,
               "melee->crit->defense pipeline produced #{dmg}, expected >= 0"

        assert loc in [:head, :body]
      end
    end
  end

  describe "combat composition: spell_damage -> apply_magic_resistance in [0, original]" do
    test "#{@iterations} random spell pipelines" do
      for _ <- 1..@iterations do
        min_hp = :rand.uniform(50)
        max_hp = min_hp + :rand.uniform(100)
        level = rand_level()
        is_mage = :rand.uniform(2) == 1

        original = Combat.spell_damage(min_hp, max_hp, level, is_mage)
        resist = :rand.uniform(150)
        reduced = Combat.apply_magic_resistance(original, resist)

        assert reduced >= 0,
               "spell->resist produced #{reduced}, expected >= 0"

        assert reduced <= original,
               "spell->resist produced #{reduced} > original #{original}"
      end
    end
  end

  describe "combat composition: hit_chance + adjust_hit_for_meditate stays in [5, 95]" do
    test "#{@iterations} random hit_chance then meditate adjustment" do
      for _ <- 1..@iterations do
        base_hit =
          Combat.hit_chance(
            rand_skill(),
            rand_stat(),
            rand_level(),
            rand_class(),
            rand_skill(),
            rand_stat(),
            rand_level(),
            rand_class()
          )

        meditating = :rand.uniform(2) == 1
        adjusted = Combat.adjust_hit_for_meditate(base_hit, meditating)

        assert adjusted >= 5 and adjusted <= 95,
               "hit_chance(#{base_hit})->meditate(#{meditating})=#{adjusted}, out of [5, 95]"
      end
    end
  end

  # ===========================================================================
  # Extreme / boundary values (fuzz)
  # ===========================================================================

  describe "extreme values: zero inputs don't crash" do
    test "hit_chance with all zeros" do
      for class_a <- @class_ids, class_b <- @class_ids do
        result = Combat.hit_chance(0, 0, 0, class_a, 0, 0, 0, class_b)
        assert is_integer(result)
      end
    end

    test "melee_damage with all zeros" do
      for class <- @class_ids do
        result = Combat.melee_damage(0, 0, 0, class, 0, 0)
        assert result >= 1
      end
    end

    test "apply_defense with zero damage and zero defense" do
      {dmg, loc} = Combat.apply_defense(0, {0, 0})
      assert dmg == 0
      assert loc in [:head, :body]
    end

    test "xp_gain with all zeros" do
      result = Combat.xp_gain(0, 0, 0, 0, 0)
      assert result >= 0
    end

    test "spell_damage with zero min/max and zero level" do
      result = Combat.spell_damage(0, 0, 0, true)
      assert result >= 0

      result2 = Combat.spell_damage(0, 0, 0, false)
      assert result2 >= 0
    end

    test "apply_magic_resistance with zero damage" do
      result = Combat.apply_magic_resistance(0, 50)
      assert result == 0
    end

    test "npc_hit_chance with zero poder" do
      for class <- @class_ids do
        result = Combat.npc_hit_chance(0, 0, 0, 0, class)
        assert is_integer(result)
      end
    end

    test "npc_damage with zeros" do
      result = Combat.npc_damage(0, 0)
      assert result >= 1
    end

    test "adjust_hit_for_meditate with zero" do
      result = Combat.adjust_hit_for_meditate(0, true)
      assert result >= 10 and result <= 90

      result2 = Combat.adjust_hit_for_meditate(0, false)
      assert result2 == 0
    end

    test "shield_block? with all zeros" do
      result = Combat.shield_block?(0, 0, 0)
      assert result == false
    end

    test "critical_hit? with zero skill" do
      result = Combat.critical_hit?(:bandido, :knuckle, 0)
      assert is_boolean(result)
    end

    test "apply_critical with zero damage" do
      result = Combat.apply_critical(0)
      assert result == 0
    end

    test "base_user_damage with level 1" do
      for class <- @class_ids do
        {min_h, max_h} = Combat.base_user_damage(1, class)
        assert min_h >= 1
        assert max_h >= 2
      end
    end
  end

  describe "extreme values: max inputs don't crash" do
    test "hit_chance with max inputs" do
      for class_a <- @class_ids, class_b <- @class_ids do
        result = Combat.hit_chance(100, 50, 50, class_a, 100, 50, 50, class_b)
        assert result >= 5 and result <= 95
      end
    end

    test "melee_damage with max inputs" do
      for class <- @class_ids do
        result = Combat.melee_damage(9999, 9999, 50, class, 9999, 9999)
        assert result >= 1
      end
    end

    test "apply_defense with max damage and max defense" do
      {dmg, loc} = Combat.apply_defense(9999, {9999, 9999})
      assert dmg >= 0
      assert loc in [:head, :body]
    end

    test "xp_gain with max inputs" do
      result = Combat.xp_gain(9999, 9999, 9999, 50, 50)
      assert result >= 0
    end

    test "spell_damage with max inputs" do
      result = Combat.spell_damage(9999, 9999, 50, true)
      assert result > 0

      result2 = Combat.spell_damage(9999, 9999, 50, false)
      assert result2 > 0
    end

    test "apply_magic_resistance with max damage and 100% resist" do
      result = Combat.apply_magic_resistance(9999, 100)
      assert result == 0
    end

    test "npc_hit_chance with max inputs" do
      for class <- @class_ids do
        result = Combat.npc_hit_chance(9999, 100, 50, 50, class)
        assert result >= 10 and result <= 90
      end
    end

    test "npc_damage with max inputs" do
      result = Combat.npc_damage(9999, 9999)
      assert result == 9999
    end

    test "base_user_damage with level 50" do
      for class <- @class_ids do
        {min_h, max_h} = Combat.base_user_damage(50, class)
        assert min_h >= 1
        assert max_h > min_h
      end
    end
  end

  describe "extreme values: hit_chance with identical attacker and defender near 50" do
    test "average hit chance with identical stats is near 50" do
      results =
        for _ <- 1..@iterations do
          skill = rand_skill()
          agi = rand_stat()
          level = rand_level()
          class = rand_class()
          Combat.hit_chance(skill, agi, level, class, skill, agi, level, class)
        end

      avg = Enum.sum(results) / @iterations
      # Class attack_mod and evasion_mod differ, so average may deviate —
      # but across all classes/levels it should stay in the ballpark.
      assert avg >= 30 and avg <= 70,
             "average identical-combatant hit_chance=#{Float.round(avg, 1)}, expected near 50"
    end
  end

  describe "extreme values: melee_damage monotonically increases with weapon damage" do
    test "average damage increases as weapon damage increases" do
      class = rand_class()
      str = rand_stat()

      avg_low =
        Enum.reduce(1..@iterations, 0, fn _, acc ->
          acc + Combat.melee_damage(5, 10, str, class)
        end) / @iterations

      avg_high =
        Enum.reduce(1..@iterations, 0, fn _, acc ->
          acc + Combat.melee_damage(50, 100, str, class)
        end) / @iterations

      assert avg_high > avg_low,
             "avg high weapon damage (#{avg_high}) should exceed avg low (#{avg_low})"
    end
  end

  describe "extreme values: xp_gain level scaling" do
    test "low level vs high NPC gives more XP than high level vs low NPC" do
      damage = 100
      give_exp = 200
      max_hp = 200

      xp_low_vs_high = Combat.xp_gain(damage, give_exp, max_hp, 1, 50)
      xp_high_vs_low = Combat.xp_gain(damage, give_exp, max_hp, 50, 1)

      assert xp_low_vs_high > xp_high_vs_low,
             "level 1 vs NPC 50 XP (#{xp_low_vs_high}) should exceed level 50 vs NPC 1 XP (#{xp_high_vs_low})"
    end
  end

  # ===========================================================================
  # Character creation property tests
  # ===========================================================================

  describe "character creation: all valid race/class/gender combos produce valid entities" do
    test "all 144 combos (6 races x 12 classes x 2 genders) succeed with HP > 0" do
      for race <- Enum.to_list(@races),
          class <- Enum.to_list(@creation_classes),
          gender <- Enum.to_list(@genders) do
        head = rand_valid_head(race, gender)

        params = %{
          name: "Test#{race}#{class}#{gender}",
          race: race,
          gender: gender,
          class: class,
          head: head,
          home_city: 1,
          account_id: "acc_test"
        }

        result = CharacterCreation.create(params)

        assert {:ok, entity} = result,
               "race=#{race} class=#{class} gender=#{gender} failed: #{inspect(result)}"

        assert entity.hp > 0,
               "race=#{race} class=#{class} gender=#{gender} HP=#{entity.hp}, expected > 0"
      end
    end
  end

  describe "character creation: stats in valid range [13, 23]" do
    test "all race/gender combos have stats within 18 +/- 5" do
      for race <- Enum.to_list(@races), gender <- Enum.to_list(@genders) do
        head = rand_valid_head(race, gender)

        params = %{
          name: "StatTest#{race}#{gender}",
          race: race,
          gender: gender,
          class: 1,
          head: head,
          home_city: 1,
          account_id: "acc_stat"
        }

        {:ok, entity} = CharacterCreation.create(params)

        for {stat_name, value} <- [
              str: entity.str,
              agi: entity.agi,
              int: entity.int,
              con: entity.con,
              cha: entity.cha
            ] do
          assert value >= 13 and value <= 23,
                 "race=#{race} gender=#{gender} #{stat_name}=#{value}, expected [13, 23]"
        end
      end
    end
  end

  describe "character creation: body IDs are always positive integers" do
    test "all race/gender combos produce positive body_id" do
      for race <- Enum.to_list(@races), gender <- Enum.to_list(@genders) do
        head = rand_valid_head(race, gender)

        params = %{
          name: "BodyTest#{race}#{gender}",
          race: race,
          gender: gender,
          class: 1,
          head: head,
          home_city: 1,
          account_id: "acc_body"
        }

        {:ok, entity} = CharacterCreation.create(params)

        assert is_integer(entity.body_id) and entity.body_id > 0,
               "race=#{race} gender=#{gender} body_id=#{entity.body_id}, expected positive integer"
      end
    end
  end

  describe "character creation: invalid names return error" do
    test "name too short" do
      params = valid_creation_params()
      result = CharacterCreation.create(%{params | name: "AB"})
      assert {:error, :name_too_short} = result
    end

    test "name too long" do
      params = valid_creation_params()
      long_name = String.duplicate("A", 31)
      result = CharacterCreation.create(%{params | name: long_name})
      assert {:error, :name_too_long} = result
    end

    test "name with special characters" do
      params = valid_creation_params()

      for bad_name <- ["Test!@#", "Hello<>World", "Name;DROP", "Test\nLine", "Name&More"] do
        result = CharacterCreation.create(%{params | name: bad_name})

        assert {:error, :name_invalid_chars} = result,
               "name '#{bad_name}' should be rejected, got: #{inspect(result)}"
      end
    end
  end

  describe "character creation: invalid race/class/gender/head/city return error" do
    test "invalid race values" do
      params = valid_creation_params()

      for bad_race <- [0, 7, -1, 100] do
        result = CharacterCreation.create(%{params | race: bad_race})
        assert {:error, _} = result, "race=#{bad_race} should fail"
      end
    end

    test "invalid class values" do
      params = valid_creation_params()

      for bad_class <- [0, 13, -1, 100] do
        result = CharacterCreation.create(%{params | class: bad_class})
        assert {:error, _} = result, "class=#{bad_class} should fail"
      end
    end

    test "invalid gender values" do
      params = valid_creation_params()

      for bad_gender <- [0, 3, -1, 100] do
        result = CharacterCreation.create(%{params | gender: bad_gender})
        assert {:error, _} = result, "gender=#{bad_gender} should fail"
      end
    end

    test "invalid head values" do
      params = valid_creation_params()

      for bad_head <- [0, -1, 9999, 99] do
        result = CharacterCreation.create(%{params | head: bad_head})
        assert {:error, :invalid_head} = result, "head=#{bad_head} should fail"
      end
    end

    test "invalid city values" do
      params = valid_creation_params()

      for bad_city <- [0, 10, -1, 100] do
        result = CharacterCreation.create(%{params | home_city: bad_city})
        assert {:error, _} = result, "city=#{bad_city} should fail"
      end
    end
  end

  describe "character creation: random valid params always succeed" do
    test "#{@iterations} random valid character creations" do
      for _ <- 1..@iterations do
        params = valid_creation_params()
        result = CharacterCreation.create(params)

        assert {:ok, entity} = result,
               "valid params #{inspect(params)} failed: #{inspect(result)}"

        assert entity.hp > 0
        assert entity.level == 1
        assert entity.xp == 0
        assert is_binary(entity.name)
        assert entity.body_id > 0
        assert entity.max_hp > 0
      end
    end
  end

  # ===========================================================================
  # Binary protocol fuzz tests
  # ===========================================================================

  describe "binary protocol fuzz: Reader.read_string8 with random payloads" do
    test "#{@iterations} random binaries never crash" do
      for _ <- 1..@iterations do
        size = :rand.uniform(64)
        payload = :crypto.strong_rand_bytes(size)

        result = Reader.read_string8(payload)

        assert result == :incomplete or match?({:ok, _, _}, result),
               "read_string8 returned unexpected: #{inspect(result)}"
      end
    end
  end

  describe "binary protocol fuzz: Reader.read_int16 with random payloads" do
    test "#{@iterations} random binaries never crash" do
      for _ <- 1..@iterations do
        size = :rand.uniform(16)
        payload = :crypto.strong_rand_bytes(size)

        result = Reader.read_int16(payload)

        assert result == :incomplete or match?({:ok, _, _}, result),
               "read_int16 returned unexpected: #{inspect(result)}"
      end
    end
  end

  describe "binary protocol fuzz: Reader.read_int32 with random payloads" do
    test "#{@iterations} random binaries never crash" do
      for _ <- 1..@iterations do
        size = :rand.uniform(16)
        payload = :crypto.strong_rand_bytes(size)

        result = Reader.read_int32(payload)

        assert result == :incomplete or match?({:ok, _, _}, result),
               "read_int32 returned unexpected: #{inspect(result)}"
      end
    end
  end

  describe "binary protocol fuzz: empty binary to all Reader functions" do
    test "read_string8 with empty binary returns :incomplete" do
      assert Reader.read_string8(<<>>) == :incomplete
    end

    test "read_int8 with empty binary returns :incomplete" do
      assert Reader.read_int8(<<>>) == :incomplete
    end

    test "read_int16 with empty binary returns :incomplete" do
      assert Reader.read_int16(<<>>) == :incomplete
    end

    test "read_int32 with empty binary returns :incomplete" do
      assert Reader.read_int32(<<>>) == :incomplete
    end

    test "read_bool with empty binary returns :incomplete" do
      assert Reader.read_bool(<<>>) == :incomplete
    end

    test "read_real32 with empty binary returns :incomplete" do
      assert Reader.read_real32(<<>>) == :incomplete
    end

    test "read_packet_id with empty binary returns :incomplete" do
      assert Reader.read_packet_id(<<>>) == :incomplete
    end
  end

  describe "binary protocol fuzz: Reader.read_int8 with random payloads" do
    test "#{@iterations} random binaries never crash" do
      for _ <- 1..@iterations do
        size = :rand.uniform(8)
        payload = :crypto.strong_rand_bytes(size)

        result = Reader.read_int8(payload)

        assert result == :incomplete or match?({:ok, _, _}, result),
               "read_int8 returned unexpected: #{inspect(result)}"
      end
    end
  end

  describe "binary protocol fuzz: Reader.read_bool with random payloads" do
    test "#{@iterations} random binaries never crash" do
      for _ <- 1..@iterations do
        size = :rand.uniform(8)
        payload = :crypto.strong_rand_bytes(size)

        result = Reader.read_bool(payload)

        assert result == :incomplete or match?({:ok, _, _}, result),
               "read_bool returned unexpected: #{inspect(result)}"
      end
    end
  end

  describe "binary protocol fuzz: Reader.read_real32 with random payloads" do
    test "#{@iterations} random binaries never crash" do
      for _ <- 1..@iterations do
        size = :rand.uniform(16)
        payload = :crypto.strong_rand_bytes(size)

        result = Reader.read_real32(payload)

        assert result == :incomplete or match?({:ok, _, _}, result),
               "read_real32 returned unexpected: #{inspect(result)}"
      end
    end
  end
end
