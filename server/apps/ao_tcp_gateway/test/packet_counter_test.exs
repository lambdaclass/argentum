defmodule AoTcpGateway.PacketCounterTest do
  use ExUnit.Case, async: true

  alias AoTcpGateway.PacketCounter

  describe "new/0" do
    test "returns empty map" do
      assert PacketCounter.new() == %{}
    end
  end

  describe "verify/2 — strictly increasing counters" do
    test "first packet with counter=1 is accepted" do
      counters = PacketCounter.new()
      assert {:ok, updated} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 1}})
      assert updated.walk == 1
    end

    test "increasing counter is accepted" do
      counters = %{walk: 5}
      assert {:ok, updated} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 6}})
      assert updated.walk == 6
    end

    test "same counter (replay) is rejected" do
      counters = %{walk: 5}
      assert {:replay, _} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 5}})
    end

    test "decreasing counter is rejected" do
      counters = %{walk: 10}
      assert {:replay, _} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 3}})
    end

    test "counter=0 on first packet is rejected (not strictly > 0)" do
      counters = PacketCounter.new()
      assert {:replay, _} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 0}})
    end
  end

  describe "verify/2 — per-command isolation" do
    test "different commands have independent counters" do
      counters = PacketCounter.new()
      {:ok, counters} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 10}})
      {:ok, counters} = PacketCounter.verify(counters, {:attack, %{packet_count: 5}})
      {:ok, counters} = PacketCounter.verify(counters, {:talk, %{message: "hi", packet_count: 3}})

      assert counters.walk == 10
      assert counters.attack == 5
      assert counters.talk == 3
    end

    test "replayed walk does not affect attack counter" do
      counters = %{walk: 10, attack: 5}
      assert {:replay, _} = PacketCounter.verify(counters, {:walk, %{direction: :north, packet_count: 10}})
      assert {:ok, _} = PacketCounter.verify(counters, {:attack, %{packet_count: 6}})
    end
  end

  describe "verify/2 — all 13 counted commands" do
    @counted_commands [
      {:talk, %{message: "hi", packet_count: 1}},
      {:walk, %{direction: :north, packet_count: 1}},
      {:attack, %{packet_count: 1}},
      {:cast_spell, %{spell_slot: 1, packet_count: 1}},
      {:drop, %{slot: 1, amount: 1, packet_count: 1}},
      {:equip_item, %{slot: 1, packet_count: 1}},
      {:change_heading, %{heading: 1, packet_count: 1}},
      {:use_item, %{slot: 1, packet_count: 1}},
      {:left_click, %{x: 1, y: 1, packet_count: 1}},
      {:work, %{skill: 1, packet_count: 1}},
      {:guild_message, %{message: "hi", packet_count: 1}},
      {:work_left_click, %{x: 1, y: 1, skill: 1, packet_count: 1}},
      {:question_gm, %{consulta: "q", tipo: "t", packet_count: 1}}
    ]

    test "all counted commands are validated" do
      for {cmd, params} <- @counted_commands do
        counters = PacketCounter.new()
        assert {:ok, updated} = PacketCounter.verify(counters, {cmd, params}),
               "Command #{cmd} should be validated"
        assert Map.get(updated, cmd) == 1
      end
    end

    test "all counted commands reject replay" do
      for {cmd, params} <- @counted_commands do
        counters = %{cmd => 1}
        assert {:replay, _} = PacketCounter.verify(counters, {cmd, params}),
               "Command #{cmd} should reject replay"
      end
    end
  end

  describe "verify/2 — uncounted commands pass through" do
    test "command without packet_count is always accepted" do
      counters = PacketCounter.new()
      assert {:ok, ^counters} = PacketCounter.verify(counters, {:pick_up, %{}})
      assert {:ok, ^counters} = PacketCounter.verify(counters, {:safe_toggle, %{}})
      assert {:ok, ^counters} = PacketCounter.verify(counters, {:commerce_start, %{}})
    end

    test "login command passes through" do
      counters = PacketCounter.new()
      assert {:ok, ^counters} = PacketCounter.verify(counters, {:login_existing_char, %{char_id: 1, session_token: "t"}})
    end
  end

  describe "verify/2 — sequential replay detection" do
    test "rapid sequential calls with same counter are all rejected" do
      counters = %{attack: 5}
      for _ <- 1..10 do
        assert {:replay, _} = PacketCounter.verify(counters, {:attack, %{packet_count: 5}})
      end
    end

    test "normal incrementing sequence passes" do
      counters = PacketCounter.new()
      {:ok, c} = PacketCounter.verify(counters, {:attack, %{packet_count: 1}})
      {:ok, c} = PacketCounter.verify(c, {:attack, %{packet_count: 2}})
      {:ok, c} = PacketCounter.verify(c, {:attack, %{packet_count: 3}})
      {:ok, c} = PacketCounter.verify(c, {:attack, %{packet_count: 100}})
      assert c.attack == 100
    end
  end
end
