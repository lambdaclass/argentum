defmodule Arena.BalanceDatParityTest do
  @moduledoc """
  Verifies that the GameData module loads Balance.dat values exactly matching
  the original VB6 Argentum Online data files. All expected values are hardcoded
  from the canonical Balance.dat / Ciudades.Dat shipped with the game.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.GameData

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---- EXP table (cumulative XP to reach each level) ----

  describe "EXP table — VB6 Balance.dat [EXP]" do
    @exp_table %{
      1 => 500,
      2 => 750,
      3 => 1_125,
      4 => 1_687,
      5 => 2_531,
      6 => 3_796,
      7 => 5_695,
      8 => 8_542,
      9 => 12_814,
      10 => 19_221,
      11 => 28_832,
      12 => 43_248,
      13 => 71_360,
      14 => 99_904,
      15 => 139_866,
      16 => 195_813,
      17 => 274_138,
      18 => 383_793,
      19 => 537_311,
      20 => 752_235,
      21 => 1_053_130,
      22 => 1_474_382,
      23 => 2_064_135,
      24 => 2_889_789,
      25 => 4_450_275,
      26 => 5_562_844,
      27 => 6_953_555,
      28 => 8_691_944,
      29 => 10_864_930,
      30 => 13_581_163,
      31 => 16_976_454,
      32 => 21_220_567,
      33 => 29_178_280,
      34 => 35_743_394,
      35 => 43_785_657,
      36 => 53_637_430,
      37 => 65_705_852,
      38 => 80_489_669,
      39 => 98_599_845,
      40 => 132_863_291,
      41 => 159_435_949,
      42 => 191_323_139,
      43 => 229_587_767,
      44 => 275_505_320,
      45 => 330_606_385,
      46 => 396_727_662
    }

    for {level, expected_xp} <- @exp_table do
      test "level #{level} requires #{expected_xp} XP" do
        assert GameData.exp_for_level(unquote(level)) == unquote(expected_xp)
      end
    end

    test "returns nil for level beyond the table" do
      assert GameData.exp_for_level(100) == nil
    end
  end

  # ---- Race modifiers (MODRAZA) ----

  describe "race modifiers — VB6 Balance.dat [MODRAZA]" do
    # Race IDs: 1=Humano, 2=Elfo, 3=ElfoOscuro, 4=Enano, 5=Gnomo, 6=Orco
    # Stat atoms: :str, :agi, :int, :cha, :con
    @race_mods %{
      # {race_id, stat} => expected modifier
      {1, :str} => 1,
      {1, :agi} => 1,
      {1, :int} => 0,
      {1, :cha} => 0,
      {1, :con} => 2,
      {2, :str} => 0,
      {2, :agi} => 2,
      {2, :int} => 2,
      {2, :cha} => 1,
      {2, :con} => 1,
      {3, :str} => 2,
      {3, :agi} => 1,
      {3, :int} => 1,
      {3, :cha} => -1,
      {3, :con} => 1,
      {4, :str} => 3,
      {4, :agi} => 0,
      {4, :int} => -3,
      {4, :cha} => -1,
      {4, :con} => 3,
      {5, :str} => -2,
      {5, :agi} => 3,
      {5, :int} => 4,
      {5, :cha} => 2,
      {5, :con} => 0,
      {6, :str} => 3,
      {6, :agi} => 1,
      {6, :int} => -2,
      {6, :cha} => -1,
      {6, :con} => 2
    }

    @race_labels %{
      1 => "Humano",
      2 => "Elfo",
      3 => "ElfoOscuro",
      4 => "Enano",
      5 => "Gnomo",
      6 => "Orco"
    }

    for {{race_id, stat}, expected} <- @race_mods do
      race_label = Map.fetch!(@race_labels, race_id)

      test "#{race_label} #{stat} modifier is #{expected}" do
        assert GameData.race_mod(unquote(race_id), unquote(stat)) == unquote(expected)
      end
    end
  end

  # ---- Class modifiers ----
  # Class IDs (from GameData @class_names):
  #   1=Mago, 2=Clerigo, 3=Paladin, 4=Cazador, 5=Trabajador, 6=Guerrero,
  #   7=Ladron, 8=Bandido, 9=Asesino, 10=Druida, 11=Bardo, 12=Pirata

  describe "class attack modifiers — VB6 Balance.dat [MODATAQUEARMAS]" do
    @attack_mods %{
      1 => 0.5,
      2 => 0.85,
      3 => 0.95,
      4 => 0.8,
      5 => 0.8,
      6 => 1.1,
      7 => 0.8,
      8 => 1.0,
      9 => 0.95,
      10 => 0.65,
      11 => 0.75,
      12 => 0.85
    }

    for {class_id, expected} <- @attack_mods do
      test "class #{class_id} attack_mod is #{expected}" do
        assert GameData.class_attack_mod(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class damage modifiers — VB6 Balance.dat [MODDANOARMAS]" do
    @damage_mods %{
      1 => 0.5,
      2 => 0.85,
      3 => 0.95,
      4 => 0.85,
      5 => 0.8,
      6 => 1.05,
      7 => 0.8,
      8 => 0.9,
      9 => 0.9,
      10 => 0.7,
      11 => 0.80,
      12 => 0.85
    }

    for {class_id, expected} <- @damage_mods do
      test "class #{class_id} damage_mod is #{expected}" do
        assert GameData.class_damage_mod(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class evasion modifiers — VB6 Balance.dat [MODEVASION]" do
    @evasion_mods %{
      1 => 0.2,
      2 => 0.8,
      3 => 0.85,
      4 => 0.9,
      5 => 0.6,
      6 => 1.0,
      7 => 0.8,
      8 => 0.75,
      9 => 0.95,
      10 => 0.65,
      11 => 1.20,
      12 => 0.85
    }

    for {class_id, expected} <- @evasion_mods do
      test "class #{class_id} evasion_mod is #{expected}" do
        assert GameData.class_evasion_mod(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class shield modifiers — VB6 Balance.dat [MODESCUDO]" do
    @shield_mods %{
      1 => 0.0,
      2 => 0.75,
      3 => 0.9,
      4 => 0.75,
      5 => 0.6,
      6 => 1.0,
      7 => 0.75,
      8 => 1.3,
      9 => 0.85,
      10 => 0.0,
      11 => 0.8,
      12 => 0.75
    }

    for {class_id, expected} <- @shield_mods do
      test "class #{class_id} shield_mod is #{expected}" do
        assert GameData.class_shield_mod(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class HP modifiers — VB6 Balance.dat [MODVIDA]" do
    @hp_mods %{
      1 => 7.5,
      2 => 8.5,
      3 => 10.0,
      4 => 10.0,
      5 => 8.5,
      6 => 10.5,
      7 => 8.0,
      8 => 9.0,
      9 => 9.0,
      10 => 8.5,
      11 => 8.5,
      12 => 10.0
    }

    for {class_id, expected} <- @hp_mods do
      test "class #{class_id} hp_mod is #{expected}" do
        assert GameData.class_hp_mod(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class skill points — VB6 Balance.dat [MODSKILLPOINTS]" do
    @skill_pts %{
      1 => 5,
      2 => 5,
      3 => 5,
      4 => 5,
      5 => 6,
      6 => 5,
      7 => 5,
      8 => 5,
      9 => 5,
      10 => 5,
      11 => 5,
      12 => 5
    }

    for {class_id, expected} <- @skill_pts do
      test "class #{class_id} skill_points is #{expected}" do
        assert GameData.class_skill_points(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class hit pre-36 — VB6 Balance.dat [GOLPE_PRE_36]" do
    @hit_pre36 %{
      1 => 1,
      2 => 2,
      3 => 3,
      4 => 3,
      5 => 3,
      6 => 3,
      7 => 3,
      8 => 3,
      9 => 3,
      10 => 2,
      11 => 2,
      12 => 3
    }

    for {class_id, expected} <- @hit_pre36 do
      test "class #{class_id} hit_pre36 is #{expected}" do
        assert GameData.class_hit_pre36(unquote(class_id)) == unquote(expected)
      end
    end
  end

  describe "class hit post-36 — VB6 Balance.dat [GOLPE_POST_36]" do
    @hit_post36 %{
      1 => 1,
      2 => 2,
      3 => 2,
      4 => 2,
      5 => 2,
      6 => 2,
      7 => 2,
      8 => 2,
      9 => 2,
      10 => 2,
      11 => 2,
      12 => 2
    }

    for {class_id, expected} <- @hit_post36 do
      test "class #{class_id} hit_post36 is #{expected}" do
        assert GameData.class_hit_post36(unquote(class_id)) == unquote(expected)
      end
    end
  end

  # ---- City spawns ----

  describe "city spawns — VB6 Ciudades.Dat" do
    # city_id => city name (for test labels)
    @city_names %{
      1 => "Ullathorpe",
      2 => "Nix",
      3 => "Banderbill",
      4 => "Lindos",
      5 => "Arghal",
      6 => "Arkhein",
      7 => "Forgat",
      8 => "Eldoria",
      9 => "Penthar"
    }

    for {city_id, city_name} <- @city_names do
      test "#{city_name} (city #{city_id}) has valid spawn with map, x, y" do
        spawn = GameData.city_spawn(unquote(city_id))
        assert is_map(spawn), "expected a map for city #{unquote(city_id)}"
        assert is_integer(spawn.map) and spawn.map > 0, "map must be a positive integer"
        assert is_integer(spawn.x) and spawn.x > 0, "x must be a positive integer"
        assert is_integer(spawn.y) and spawn.y > 0, "y must be a positive integer"
      end
    end

    # Spot-check known fallback values
    test "Ullathorpe spawns on map 1" do
      spawn = GameData.city_spawn(1)
      assert spawn.map == 1
    end

    test "Nix spawns on map 34" do
      spawn = GameData.city_spawn(2)
      assert spawn.map == 34
    end

    test "Banderbill spawns on map 59" do
      spawn = GameData.city_spawn(3)
      assert spawn.map == 59
    end
  end
end
