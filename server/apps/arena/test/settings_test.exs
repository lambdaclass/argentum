defmodule Arena.SettingsTest do
  @moduledoc "Tests for Arena.Settings runtime-tunable configuration."
  use ExUnit.Case, async: false

  # Settings uses ETS, so we need the GenServer running
  setup do
    case Arena.Settings.start_link() do
      {:ok, pid} -> on_exit(fn -> GenServer.stop(pid) end)
      {:error, {:already_started, pid}} ->
        # Reset all settings before each test
        Arena.Settings.reset_all()
        on_exit(fn -> Arena.Settings.reset_all() end)
        {:ok, pid: pid}
    end

    :ok
  end

  describe "get/2" do
    test "returns default value for known setting" do
      assert Arena.Settings.get(:xp_multiplier) == 1.0
      assert Arena.Settings.get(:gold_multiplier) == 1.0
      assert Arena.Settings.get(:chat_cooldown_ms) == 1000
      assert Arena.Settings.get(:attack_cooldown_ms) == 1500
    end

    test "returns nil for unknown setting without default" do
      assert Arena.Settings.get(:nonexistent_setting) == nil
    end

    test "returns explicit default for unknown setting" do
      assert Arena.Settings.get(:nonexistent_setting, 42) == 42
    end

    test "returns overridden value after set" do
      Arena.Settings.set(:xp_multiplier, 2.5)
      assert Arena.Settings.get(:xp_multiplier) == 2.5
    end
  end

  describe "set/2" do
    test "overrides a default" do
      Arena.Settings.set(:gold_multiplier, 3.0)
      assert Arena.Settings.get(:gold_multiplier) == 3.0
    end

    test "can set arbitrary keys" do
      Arena.Settings.set(:custom_flag, true)
      assert Arena.Settings.get(:custom_flag) == true
    end

    test "overwrites previous override" do
      Arena.Settings.set(:xp_multiplier, 2.0)
      Arena.Settings.set(:xp_multiplier, 5.0)
      assert Arena.Settings.get(:xp_multiplier) == 5.0
    end
  end

  describe "reset/1" do
    test "removes override, falls back to default" do
      Arena.Settings.set(:xp_multiplier, 10.0)
      assert Arena.Settings.get(:xp_multiplier) == 10.0
      Arena.Settings.reset(:xp_multiplier)
      assert Arena.Settings.get(:xp_multiplier) == 1.0
    end

    test "reset of unset key is a no-op" do
      Arena.Settings.reset(:xp_multiplier)
      assert Arena.Settings.get(:xp_multiplier) == 1.0
    end
  end

  describe "reset_all/0" do
    test "clears all overrides" do
      Arena.Settings.set(:xp_multiplier, 5.0)
      Arena.Settings.set(:gold_multiplier, 3.0)
      Arena.Settings.reset_all()
      assert Arena.Settings.get(:xp_multiplier) == 1.0
      assert Arena.Settings.get(:gold_multiplier) == 1.0
    end
  end

  describe "all/0" do
    test "returns defaults when no overrides" do
      all = Arena.Settings.all()
      assert all[:xp_multiplier] == 1.0
      assert all[:gold_multiplier] == 1.0
      assert all[:chat_cooldown_ms] == 1000
    end

    test "returns overrides merged with defaults" do
      Arena.Settings.set(:xp_multiplier, 99.0)
      all = Arena.Settings.all()
      assert all[:xp_multiplier] == 99.0
      assert all[:gold_multiplier] == 1.0
    end
  end

  describe "defaults/0" do
    test "returns all compiled defaults" do
      defaults = Arena.Settings.defaults()
      assert is_map(defaults)
      assert Map.has_key?(defaults, :xp_multiplier)
      assert Map.has_key?(defaults, :gold_multiplier)
      assert Map.has_key?(defaults, :drop_rate_multiplier)
    end
  end

  describe "default/1" do
    test "returns the compiled default for a specific key" do
      assert Arena.Settings.default(:xp_multiplier) == 1.0
      assert Arena.Settings.default(:attack_cooldown_ms) == 1500
    end

    test "returns nil for unknown key" do
      assert Arena.Settings.default(:nonexistent) == nil
    end
  end

  describe "adversarial" do
    test "concurrent reads during writes don't crash" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            Arena.Settings.set(:xp_multiplier, i * 1.0)
            Arena.Settings.get(:xp_multiplier)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &is_float/1)
    end

    test "setting 0 or negative values" do
      Arena.Settings.set(:xp_multiplier, 0.0)
      assert Arena.Settings.get(:xp_multiplier) == 0.0

      Arena.Settings.set(:xp_multiplier, -1.0)
      assert Arena.Settings.get(:xp_multiplier) == -1.0
    end

    test "setting non-numeric types" do
      Arena.Settings.set(:xp_multiplier, :disabled)
      assert Arena.Settings.get(:xp_multiplier) == :disabled
    end
  end
end
