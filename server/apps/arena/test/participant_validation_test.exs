defmodule Arena.Events.ParticipantValidationTest do
  @moduledoc """
  Tests for Arena.Events.ParticipantValidation — pure registration checks.

  Covers each of the 11 VB6 validation checks individually, plus edge cases
  for boundary values (exact level min/max, exact gold amount).
  """
  use ExUnit.Case, async: true

  alias Arena.Events.ParticipantValidation, as: PV

  # ── Helpers ──────────────────────────────────────────────────────────

  # Build a valid entity that passes all checks. Tests override specific fields.
  defp valid_entity(overrides \\ %{}) do
    base = %{
      char_id: 1,
      dead: false,
      penalty: 0,
      trade_partner_id: nil,
      mounted: false,
      navigating: false,
      gold: 10_000,
      level: 25
    }

    Map.merge(base, overrides)
  end

  defp default_config(overrides \\ %{}) do
    base = %{
      entry_fee: 500,
      min_level: 10,
      max_level: 45,
      safe_zone: false
    }

    Map.merge(base, overrides)
  end

  # ── All-clear ────────────────────────────────────────────────────────

  describe "validate_registration/3 — all clear" do
    test "valid entity passes all checks" do
      entity = valid_entity()
      config = default_config()

      assert :ok == PV.validate_registration(entity, config)
    end

    test "valid entity passes with empty registered set" do
      entity = valid_entity()
      config = default_config()

      assert :ok == PV.validate_registration(entity, config, MapSet.new())
    end
  end

  # ── Individual checks ───────────────────────────────────────────────

  describe "dead check" do
    test "dead entity is rejected" do
      entity = valid_entity(%{dead: true})

      assert {:error, :dead} == PV.validate_registration(entity, default_config())
    end
  end

  describe "jailed check" do
    test "entity with penalty > 0 is rejected" do
      entity = valid_entity(%{penalty: 5})

      assert {:error, :jailed} == PV.validate_registration(entity, default_config())
    end

    test "entity with penalty == 0 passes" do
      entity = valid_entity(%{penalty: 0})

      assert :ok == PV.validate_registration(entity, default_config())
    end
  end

  describe "trading check" do
    test "entity currently trading is rejected" do
      entity = valid_entity(%{trade_partner_id: 42})

      assert {:error, :trading} == PV.validate_registration(entity, default_config())
    end
  end

  describe "mounted check" do
    test "mounted entity is rejected" do
      entity = valid_entity(%{mounted: true})

      assert {:error, :mounted} == PV.validate_registration(entity, default_config())
    end
  end

  describe "navigating check" do
    test "navigating entity is rejected" do
      entity = valid_entity(%{navigating: true})

      assert {:error, :navigating} == PV.validate_registration(entity, default_config())
    end
  end

  describe "gold check" do
    test "entity without enough gold is rejected" do
      entity = valid_entity(%{gold: 499})
      config = default_config(%{entry_fee: 500})

      assert {:error, :insufficient_gold} == PV.validate_registration(entity, config)
    end

    test "entity with exactly enough gold passes" do
      entity = valid_entity(%{gold: 500})
      config = default_config(%{entry_fee: 500})

      assert :ok == PV.validate_registration(entity, config)
    end

    test "zero entry fee skips gold check" do
      entity = valid_entity(%{gold: 0})
      config = default_config(%{entry_fee: 0})

      assert :ok == PV.validate_registration(entity, config)
    end

    test "no entry_fee key in config skips gold check" do
      entity = valid_entity(%{gold: 0})
      config = Map.delete(default_config(), :entry_fee)

      assert :ok == PV.validate_registration(entity, config)
    end
  end

  describe "level range checks" do
    test "level below min is rejected" do
      entity = valid_entity(%{level: 9})
      config = default_config(%{min_level: 10})

      assert {:error, :level_too_low} == PV.validate_registration(entity, config)
    end

    test "level exactly at min passes" do
      entity = valid_entity(%{level: 10})
      config = default_config(%{min_level: 10})

      assert :ok == PV.validate_registration(entity, config)
    end

    test "level above max is rejected" do
      entity = valid_entity(%{level: 46})
      config = default_config(%{max_level: 45})

      assert {:error, :level_too_high} == PV.validate_registration(entity, config)
    end

    test "level exactly at max passes" do
      entity = valid_entity(%{level: 45})
      config = default_config(%{max_level: 45})

      assert :ok == PV.validate_registration(entity, config)
    end

    test "no min_level in config skips min check" do
      entity = valid_entity(%{level: 1})
      config = Map.delete(default_config(), :min_level)

      assert :ok == PV.validate_registration(entity, config)
    end

    test "no max_level in config skips max check" do
      entity = valid_entity(%{level: 999})
      config = Map.delete(default_config(), :max_level)

      assert :ok == PV.validate_registration(entity, config)
    end
  end

  describe "safe zone check" do
    test "entity in safe zone is rejected" do
      entity = valid_entity()
      config = default_config(%{safe_zone: true})

      assert {:error, :in_safe_zone} == PV.validate_registration(entity, config)
    end

    test "entity not in safe zone passes" do
      entity = valid_entity()
      config = default_config(%{safe_zone: false})

      assert :ok == PV.validate_registration(entity, config)
    end
  end

  describe "already registered check" do
    test "entity already registered is rejected" do
      entity = valid_entity(%{char_id: 7})
      registered = MapSet.new([7])

      assert {:error, :already_registered} ==
               PV.validate_registration(entity, default_config(), registered)
    end

    test "entity not in registered set passes" do
      entity = valid_entity(%{char_id: 7})
      registered = MapSet.new([1, 2, 3])

      assert :ok == PV.validate_registration(entity, default_config(), registered)
    end
  end

  # ── Multiple violations ─────────────────────────────────────────────

  describe "multiple violations" do
    test "first failing check wins (dead takes precedence)" do
      entity = valid_entity(%{dead: true, penalty: 5, mounted: true})

      assert {:error, :dead} == PV.validate_registration(entity, default_config())
    end

    test "jailed takes precedence over trading" do
      entity = valid_entity(%{penalty: 3, trade_partner_id: 10})

      assert {:error, :jailed} == PV.validate_registration(entity, default_config())
    end

    test "trading takes precedence over mounted" do
      entity = valid_entity(%{trade_partner_id: 10, mounted: true})

      assert {:error, :trading} == PV.validate_registration(entity, default_config())
    end

    test "mounted takes precedence over navigating" do
      entity = valid_entity(%{mounted: true, navigating: true})

      assert {:error, :mounted} == PV.validate_registration(entity, default_config())
    end

    test "navigating takes precedence over insufficient gold" do
      entity = valid_entity(%{navigating: true, gold: 0})
      config = default_config(%{entry_fee: 500})

      assert {:error, :navigating} == PV.validate_registration(entity, config)
    end
  end
end
