defmodule Arena.Events.EventSchedulerTest do
  @moduledoc """
  Tests for the EventScheduler GenServer (VB6: ModEventos / CheckEvento).

  Validates:
    - Load/add/remove/list schedule entries
    - Tick triggers events at matching hour
    - Tick does NOT trigger if already active or disabled
    - Force event starts immediately regardless of hour
    - Event auto-ends after configured duration
    - Edge cases: empty schedule, multiple events same hour, hour wraparound (23 -> 0)
    - Schedule entry validation (invalid hour, missing fields)
  """
  use ExUnit.Case, async: true

  alias Arena.Events.EventScheduler
  alias Arena.Events.EventScheduler.ScheduleEntry

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_entry(overrides \\ %{}) do
    defaults = %{
      id: "test_#{System.unique_integer([:positive])}",
      event_type: :xp_bonus,
      hour: 12,
      duration_minutes: 30,
      event_config: %{},
      enabled: true
    }

    attrs = Map.merge(defaults, overrides)
    struct!(ScheduleEntry, attrs)
  end

  defp start_scheduler(opts \\ []) do
    name = :"scheduler_#{System.unique_integer([:positive])}"
    clock_fun = Keyword.get(opts, :clock_fun, fn -> 12 end)
    schedule = Keyword.get(opts, :schedule, [])
    notify = Keyword.get(opts, :notify, self())

    # Use a very large tick interval so ticks don't fire automatically
    tick_interval = Keyword.get(opts, :tick_interval, 60_000_000)

    {:ok, pid} =
      EventScheduler.start_link(
        name: name,
        clock_fun: clock_fun,
        schedule: schedule,
        tick_interval: tick_interval,
        notify: notify
      )

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {pid, name}
  end

  # ── Load schedule config ─────────────────────────────────────────────

  describe "load_schedule/2" do
    test "loads a list of schedule entries" do
      {_pid, name} = start_scheduler()
      entry1 = make_entry(%{id: "xp_noon", hour: 12})
      entry2 = make_entry(%{id: "gold_evening", event_type: :gold_bonus, hour: 18})

      assert :ok = EventScheduler.load_schedule(name, [entry1, entry2])
      assert {:ok, [^entry1, ^entry2]} = EventScheduler.list_schedules(name)
    end

    test "replaces existing schedule" do
      entry_old = make_entry(%{id: "old"})
      {_pid, name} = start_scheduler(schedule: [entry_old])

      entry_new = make_entry(%{id: "new", hour: 5})
      assert :ok = EventScheduler.load_schedule(name, [entry_new])
      assert {:ok, [^entry_new]} = EventScheduler.list_schedules(name)
    end

    test "rejects invalid entries in batch" do
      {_pid, name} = start_scheduler()
      bad = make_entry(%{id: "bad", hour: 25})

      assert {:error, {:invalid_hour, 25}} = EventScheduler.load_schedule(name, [bad])
    end

    test "accepts empty schedule" do
      {_pid, name} = start_scheduler()
      assert :ok = EventScheduler.load_schedule(name, [])
      assert {:ok, []} = EventScheduler.list_schedules(name)
    end
  end

  # ── Add/remove/list schedules ────────────────────────────────────────

  describe "add_schedule/2" do
    test "adds a single entry" do
      {_pid, name} = start_scheduler()
      entry = make_entry(%{id: "new_event"})

      assert :ok = EventScheduler.add_schedule(name, entry)
      assert {:ok, [^entry]} = EventScheduler.list_schedules(name)
    end

    test "rejects duplicate id" do
      entry = make_entry(%{id: "dup"})
      {_pid, name} = start_scheduler(schedule: [entry])

      assert {:error, :duplicate_id} = EventScheduler.add_schedule(name, make_entry(%{id: "dup"}))
    end

    test "rejects invalid entry" do
      {_pid, name} = start_scheduler()
      bad = make_entry(%{id: "bad", hour: -1})

      assert {:error, {:invalid_hour, -1}} = EventScheduler.add_schedule(name, bad)
    end
  end

  describe "remove_schedule/2" do
    test "removes an entry by id" do
      entry = make_entry(%{id: "removable"})
      {_pid, name} = start_scheduler(schedule: [entry])

      assert :ok = EventScheduler.remove_schedule(name, "removable")
      assert {:ok, []} = EventScheduler.list_schedules(name)
    end

    test "returns error for unknown id" do
      {_pid, name} = start_scheduler()
      assert {:error, :not_found} = EventScheduler.remove_schedule(name, "nonexistent")
    end
  end

  describe "list_schedules/1" do
    test "returns all configured entries" do
      e1 = make_entry(%{id: "a", hour: 0})
      e2 = make_entry(%{id: "b", hour: 23})
      {_pid, name} = start_scheduler(schedule: [e1, e2])

      assert {:ok, [^e1, ^e2]} = EventScheduler.list_schedules(name)
    end

    test "returns empty list when no entries" do
      {_pid, name} = start_scheduler()
      assert {:ok, []} = EventScheduler.list_schedules(name)
    end
  end

  # ── Tick triggers event at matching hour ─────────────────────────────

  describe "tick triggers" do
    test "starts event when current hour matches" do
      entry = make_entry(%{id: "noon_xp", hour: 12, duration_minutes: 30})
      {pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      send(pid, :tick)
      assert_receive {:event_started, "noon_xp", ^entry}, 500

      {:ok, active} = EventScheduler.list_active(name)
      assert Map.has_key?(active, "noon_xp")
    end

    test "does NOT trigger if already active" do
      entry = make_entry(%{id: "once", hour: 12, duration_minutes: 60})
      {pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      # First tick starts it
      send(pid, :tick)
      assert_receive {:event_started, "once", _}, 500

      # Second tick should not start it again
      send(pid, :tick)
      refute_receive {:event_started, "once", _}, 200

      {:ok, active} = EventScheduler.list_active(name)
      assert map_size(active) == 1
    end

    test "does NOT trigger if entry is disabled" do
      entry = make_entry(%{id: "disabled", hour: 12, enabled: false})
      {pid, _name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      send(pid, :tick)
      refute_receive {:event_started, "disabled", _}, 200
    end

    test "does NOT trigger if hour does not match" do
      entry = make_entry(%{id: "evening", hour: 18})
      {pid, _name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      send(pid, :tick)
      refute_receive {:event_started, "evening", _}, 200
    end

    test "multiple events at the same hour all trigger" do
      e1 = make_entry(%{id: "xp_noon", event_type: :xp_bonus, hour: 12, duration_minutes: 30})
      e2 = make_entry(%{id: "gold_noon", event_type: :gold_bonus, hour: 12, duration_minutes: 30})
      {pid, name} = start_scheduler(schedule: [e1, e2], clock_fun: fn -> 12 end)

      send(pid, :tick)
      assert_receive {:event_started, "xp_noon", _}, 500
      assert_receive {:event_started, "gold_noon", _}, 500

      {:ok, active} = EventScheduler.list_active(name)
      assert map_size(active) == 2
    end

    test "hour wraparound: triggers at hour 0 after hour 23" do
      hour_ref = :atomics.new(1, signed: false)
      :atomics.put(hour_ref, 1, 23)

      clock_fun = fn -> :atomics.get(hour_ref, 1) end

      entry_23 = make_entry(%{id: "late_night", hour: 23, duration_minutes: 30})
      entry_0 = make_entry(%{id: "midnight", hour: 0, duration_minutes: 30})

      {pid, name} =
        start_scheduler(schedule: [entry_23, entry_0], clock_fun: clock_fun)

      # Hour 23 tick
      send(pid, :tick)
      assert_receive {:event_started, "late_night", _}, 500
      refute_receive {:event_started, "midnight", _}, 200

      # Simulate hour rolling to 0
      :atomics.put(hour_ref, 1, 0)
      send(pid, :tick)
      assert_receive {:event_started, "midnight", _}, 500

      {:ok, active} = EventScheduler.list_active(name)
      assert Map.has_key?(active, "late_night")
      assert Map.has_key?(active, "midnight")
    end

    test "empty schedule does not crash on tick" do
      {pid, name} = start_scheduler(schedule: [], clock_fun: fn -> 12 end)
      send(pid, :tick)

      # Should still be alive and have no active events
      assert Process.alive?(pid)
      assert {:ok, %{}} = EventScheduler.list_active(name)
    end
  end

  # ── Force event ──────────────────────────────────────────────────────

  describe "force_event/2" do
    test "starts event immediately regardless of hour" do
      entry = make_entry(%{id: "forced", hour: 3, duration_minutes: 10})
      {_pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      assert :ok = EventScheduler.force_event(name, "forced")
      assert_receive {:event_started, "forced", ^entry}, 500

      {:ok, active} = EventScheduler.list_active(name)
      assert Map.has_key?(active, "forced")
    end

    test "returns error for unknown id" do
      {_pid, name} = start_scheduler()
      assert {:error, :not_found} = EventScheduler.force_event(name, "nonexistent")
    end

    test "returns error if event is already active" do
      entry = make_entry(%{id: "once", hour: 12, duration_minutes: 60})
      {_pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      assert :ok = EventScheduler.force_event(name, "once")
      assert {:error, :already_active} = EventScheduler.force_event(name, "once")
    end
  end

  # ── Event end callback cleans up active_events ───────────────────────

  describe "event_ended callback" do
    test "cleans up active_events on duration expiry" do
      entry = make_entry(%{id: "short", hour: 12, duration_minutes: 1})
      {pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      assert :ok = EventScheduler.force_event(name, "short")
      assert_receive {:event_started, "short", _}, 500

      {:ok, active_before} = EventScheduler.list_active(name)
      assert Map.has_key?(active_before, "short")

      # Simulate the timer firing
      send(pid, {:event_ended, "short"})
      assert_receive {:event_ended, "short"}, 500

      {:ok, active_after} = EventScheduler.list_active(name)
      refute Map.has_key?(active_after, "short")
    end

    test "ignores event_ended for unknown event id" do
      {pid, name} = start_scheduler()

      send(pid, {:event_ended, "ghost"})
      # Should not crash
      assert Process.alive?(pid)
      assert {:ok, %{}} = EventScheduler.list_active(name)
    end

    test "after event ends, tick can restart it" do
      entry = make_entry(%{id: "recurring", hour: 12, duration_minutes: 30})
      {pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      # Start via tick
      send(pid, :tick)
      assert_receive {:event_started, "recurring", _}, 500

      # End it
      send(pid, {:event_ended, "recurring"})
      assert_receive {:event_ended, "recurring"}, 500

      # Tick again should restart
      send(pid, :tick)
      assert_receive {:event_started, "recurring", _}, 500

      {:ok, active} = EventScheduler.list_active(name)
      assert Map.has_key?(active, "recurring")
    end
  end

  # ── Duration: event auto-ends after configured minutes ───────────────

  describe "auto-end duration" do
    test "event auto-ends after duration_minutes" do
      # Use a very short duration so the timer fires quickly
      entry = make_entry(%{id: "quick", hour: 12, duration_minutes: 1})
      {_pid, name} = start_scheduler(schedule: [entry], clock_fun: fn -> 12 end)

      assert :ok = EventScheduler.force_event(name, "quick")
      assert_receive {:event_started, "quick", _}, 500

      # The real timer is set for 1 minute (60_000 ms). We can't wait that long
      # in tests, so we verify the timer ref exists in the active event.
      {:ok, active} = EventScheduler.list_active(name)
      assert active["quick"].timer_ref != nil
      assert is_reference(active["quick"].timer_ref)
    end
  end

  # ── Schedule entry validation ────────────────────────────────────────

  describe "schedule entry validation" do
    test "rejects hour below 0" do
      {_pid, name} = start_scheduler()
      bad = make_entry(%{id: "bad", hour: -1})
      assert {:error, {:invalid_hour, -1}} = EventScheduler.add_schedule(name, bad)
    end

    test "rejects hour above 23" do
      {_pid, name} = start_scheduler()
      bad = make_entry(%{id: "bad", hour: 24})
      assert {:error, {:invalid_hour, 24}} = EventScheduler.add_schedule(name, bad)
    end

    test "rejects non-integer hour" do
      {_pid, name} = start_scheduler()
      bad = %ScheduleEntry{id: "bad", event_type: :xp_bonus, hour: "noon", duration_minutes: 30}
      assert {:error, {:invalid_hour, "noon"}} = EventScheduler.add_schedule(name, bad)
    end

    test "rejects zero duration" do
      {_pid, name} = start_scheduler()
      bad = make_entry(%{id: "bad", duration_minutes: 0})
      assert {:error, {:invalid_duration, 0}} = EventScheduler.add_schedule(name, bad)
    end

    test "rejects negative duration" do
      {_pid, name} = start_scheduler()
      bad = make_entry(%{id: "bad", duration_minutes: -5})
      assert {:error, {:invalid_duration, -5}} = EventScheduler.add_schedule(name, bad)
    end

    test "rejects invalid event type" do
      {_pid, name} = start_scheduler()
      bad = %ScheduleEntry{id: "bad", event_type: :fireworks, hour: 12, duration_minutes: 30}
      assert {:error, {:invalid_event_type, :fireworks}} = EventScheduler.add_schedule(name, bad)
    end

    test "rejects non-struct entries" do
      {_pid, name} = start_scheduler()
      assert {:error, :invalid_entry} = EventScheduler.add_schedule(name, %{id: "bad"})
    end

    test "init rejects invalid schedule entries" do
      bad = make_entry(%{id: "bad", hour: 99})
      name = :"scheduler_#{System.unique_integer([:positive])}"

      Process.flag(:trap_exit, true)

      result =
        EventScheduler.start_link(
          name: name,
          schedule: [bad],
          tick_interval: 60_000_000
        )

      assert {:error, {:invalid_hour, 99}} = result
    end
  end
end
