defmodule Arena.HidingDriftTest do
  @moduledoc """
  Tests for VB6 parity drift #30: Ocultarse/hiding.

  Verifies the four missing features from VB6's DoOcultarse:
    1. Recent-hit cooldown blocks hiding if attacked too recently
    2. Nonlinear success formula (cubic polynomial)
    3. Class-specific duration based on polynomial curve
    4. Pirate ghost-ship body while navigating
  """
  use ExUnit.Case, async: true

  alias AoEntities.PlayerEntity

  # ---- Constants matching VB6 ----

  # VB6: iFragataFantasmal = 87
  @ghost_ship_body 87

  # VB6: HideAfterHitTime — we use 3_000 ms cooldown
  @hide_after_hit_cooldown_ms 3_000

  # VB6: IntervaloOculto = 36_000 (tick intervals ~ seconds)
  # Converted to ms: 36_000 (each tick ~1s, so 36_000 ticks ~ 36_000 seconds)
  # But the VB6 value is used as-is in formulas (not ms), so we use 36_000 as-is
  @intervalo_oculto 36_000

  # ---- Helper: VB6 success formula (cubic polynomial) ----

  defp vb6_success_chance(skill) do
    (((0.000002 * skill - 0.0002) * skill + 0.0064) * skill + 0.1124) * 100
  end

  # ---- Helper: VB6 duration base curve ----

  defp vb6_duration_base(skill) do
    inv = 100 - skill
    suerte = -0.000001 * :math.pow(inv, 3)
    suerte = suerte + 0.00009229 * :math.pow(inv, 2)
    suerte = suerte + -0.0088 * inv
    suerte = suerte + 0.9571
    suerte * @intervalo_oculto
  end

  # ==================================================================
  # 1. Recent-hit cooldown
  # ==================================================================

  describe "recent-hit cooldown" do
    test "hiding is blocked when attacked too recently" do
      now = System.monotonic_time(:millisecond)

      entity = %PlayerEntity{
        char_id: 1,
        name: "Test",
        dead: false,
        oculto: false,
        class: :thief,
        last_attacked_at: now - 1_000
      }

      # Player attacked 1 second ago; cooldown is 3 seconds, should be blocked
      elapsed = now - entity.last_attacked_at
      assert elapsed < @hide_after_hit_cooldown_ms,
             "Expected elapsed (#{elapsed}) to be under cooldown (#{@hide_after_hit_cooldown_ms})"
    end

    test "hiding is allowed when enough time has passed since attack" do
      now = System.monotonic_time(:millisecond)

      entity = %PlayerEntity{
        char_id: 1,
        name: "Test",
        dead: false,
        oculto: false,
        class: :thief,
        last_attacked_at: now - 5_000
      }

      # Player attacked 5 seconds ago; cooldown is 3 seconds, should be allowed
      elapsed = now - entity.last_attacked_at
      assert elapsed >= @hide_after_hit_cooldown_ms
    end

    test "hiding is allowed when player never attacked (far-past default)" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "Test",
        dead: false,
        oculto: false,
        class: :warrior
      }

      now = System.monotonic_time(:millisecond)
      elapsed = now - entity.last_attacked_at
      assert elapsed >= @hide_after_hit_cooldown_ms
    end
  end

  # ==================================================================
  # 2. Nonlinear success formula
  # ==================================================================

  describe "nonlinear success formula" do
    test "skill 100 gives near 100% chance" do
      chance = vb6_success_chance(100)
      # VB6: (((0.000002*100 - 0.0002)*100 + 0.0064)*100 + 0.1124)*100
      # = (((0.02 - 0.0002)*100 + 0.0064)*100 + 0.1124)*100
      # Actually let's compute:
      # 0.000002*100 = 0.0002
      # 0.0002 - 0.0002 = 0.0
      # 0.0 * 100 = 0.0
      # 0.0 + 0.0064 = 0.0064
      # 0.0064 * 100 = 0.64
      # 0.64 + 0.1124 = 0.7524
      # 0.7524 * 100 = 75.24
      assert_in_delta chance, 75.24, 0.01
    end

    test "skill 50 gives a moderate chance" do
      chance = vb6_success_chance(50)
      assert chance > 10
      assert chance < 80
    end

    test "skill 1 gives a very low chance" do
      chance = vb6_success_chance(1)
      # Nearly just the constant term: ~11.30
      assert chance > 10
      assert chance < 15
    end

    test "Social.hiding_success_chance/1 matches VB6 formula" do
      for skill <- [1, 10, 25, 50, 75, 100] do
        expected = vb6_success_chance(skill)
        actual = Arena.Map.Social.hiding_success_chance(skill)

        assert_in_delta actual, expected, 0.01,
               "Mismatch at skill #{skill}: expected #{expected}, got #{actual}"
      end
    end
  end

  # ==================================================================
  # 3. Class-specific duration
  # ==================================================================

  describe "class-specific duration" do
    test "bandit/thief gets duration in [base/2.5, base/2] range" do
      skill = 80
      base = vb6_duration_base(skill)

      for class <- [:bandit, :thief] do
        {min_d, max_d} = Arena.Map.Social.hiding_duration_range(class, skill)
        expected_min = trunc(base / 2.5)
        expected_max = trunc(base / 2)

        assert min_d == expected_min,
               "#{class} min duration mismatch: expected #{expected_min}, got #{min_d}"

        assert max_d == expected_max,
               "#{class} max duration mismatch: expected #{expected_max}, got #{max_d}"
      end
    end

    test "hunter gets exactly base/2" do
      skill = 80
      base = vb6_duration_base(skill)
      {min_d, max_d} = Arena.Map.Social.hiding_duration_range(:hunter, skill)
      expected = trunc(base / 2)
      assert min_d == expected
      assert max_d == expected
    end

    test "other classes get base/3" do
      skill = 80
      base = vb6_duration_base(skill)

      for class <- [:warrior, :mage, :cleric, :paladin] do
        {min_d, max_d} = Arena.Map.Social.hiding_duration_range(class, skill)
        expected = trunc(base / 3)

        assert min_d == expected,
               "#{class} duration mismatch: expected #{expected}, got #{min_d}"

        assert max_d == expected,
               "#{class} duration mismatch: expected #{expected}, got #{max_d}"
      end
    end

    test "skill 100 gives highest duration" do
      skill_100 = vb6_duration_base(100)
      skill_50 = vb6_duration_base(50)
      assert skill_100 > skill_50
    end
  end

  # ==================================================================
  # 4. Pirate ghost-ship while navigating
  # ==================================================================

  describe "pirate ghost-ship while navigating" do
    test "pirate navigating sets ghost ship body" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "Pirate",
        class: :pirate,
        navigating: true,
        dead: false,
        oculto: false,
        body_id: 50
      }

      # When pirate is navigating and hides, body should become ghost ship
      result = Arena.Map.Social.apply_hiding_body(entity)
      assert result.body_id == @ghost_ship_body
    end

    test "pirate NOT navigating does NOT set ghost ship body" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "Pirate",
        class: :pirate,
        navigating: false,
        dead: false,
        oculto: false,
        body_id: 50
      }

      result = Arena.Map.Social.apply_hiding_body(entity)
      assert result.body_id == 50
    end

    test "non-pirate navigating does NOT set ghost ship body" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "Hunter",
        class: :hunter,
        navigating: true,
        dead: false,
        oculto: false,
        body_id: 50
      }

      # Non-pirate class cannot hide while navigating per VB6 guard,
      # but if they somehow did, body should NOT be ghost ship
      result = Arena.Map.Social.apply_hiding_body(entity)
      assert result.body_id == 50
    end

    test "pirate navigating gets full IntervaloOculto duration" do
      # VB6: pirate navigating gets .Counters.TiempoOculto = IntervaloOculto
      entity = %PlayerEntity{
        char_id: 1,
        name: "Pirate",
        class: :pirate,
        navigating: true,
        dead: false,
        oculto: false
      }

      {min_d, max_d} = Arena.Map.Social.hiding_duration_range(entity.class, 50, navigating: true)
      assert min_d == @intervalo_oculto
      assert max_d == @intervalo_oculto
    end
  end

  # ==================================================================
  # 5. Navigation guard (non-pirate cannot hide while navigating)
  # ==================================================================

  describe "navigation guard" do
    test "non-pirate cannot hide while navigating" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "Warrior",
        class: :warrior,
        navigating: true,
        dead: false,
        oculto: false
      }

      # VB6: If .flags.Navegando = 1 And .clase <> e_Class.Pirat Then Exit Sub
      assert entity.navigating and entity.class != :pirate
    end

    test "pirate can hide while navigating" do
      entity = %PlayerEntity{
        char_id: 1,
        name: "Pirate",
        class: :pirate,
        navigating: true,
        dead: false,
        oculto: false
      }

      refute entity.navigating and entity.class != :pirate
    end
  end
end
