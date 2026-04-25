defmodule Arena.Map.EffectsTest do
  use ExUnit.Case, async: true

  alias Arena.Map.Effects

  describe "run/2" do
    test "empty list is a no-op" do
      assert :ok = Effects.run(%{sessions: %{}}, [])
    end

    test ":send routes the envelope to the session pid via Egress" do
      state = %{sessions: %{42 => self()}}
      assert :ok = Effects.run(state, [Effects.send(42, "hello")])
      assert_receive {:egress, %{class: :critical, payload: "hello"}}
    end

    test ":send to a missing session is silently dropped" do
      state = %{sessions: %{}}
      assert :ok = Effects.run(state, [Effects.send(999, "x")])
      refute_receive _, 50
    end

    test "preserves order across multiple :send effects to the same session" do
      state = %{sessions: %{1 => self()}}

      effects = [
        Effects.send(1, "aa"),
        Effects.send(1, "bb"),
        Effects.send(1, "cc")
      ]

      assert :ok = Effects.run(state, effects)
      assert_receive {:egress, %{payload: "aa"}}
      assert_receive {:egress, %{payload: "bb"}}
      assert_receive {:egress, %{payload: "cc"}}
    end

    test "unknown effect raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Effects.run(%{sessions: %{}}, [{:bogus, 1, 2}])
      end
    end
  end

  describe "send/3 envelope construction" do
    test "defaults class via AoProtocol.Classify.class_for/1 (first 2 bytes as packet ID)" do
      # console_msg is :critical by classifier
      console_id = AoProtocol.PacketIds.Server.console_msg()
      packet = <<console_id::little-signed-integer-16, "hi"::binary>>

      {:send, _, env} = Effects.send(:p, packet)
      assert env.class == :critical
      assert env.coalesce_key == nil
    end

    test "defaults to :coalesce class with packet id as key for stat-stream packets" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:send, _, env} = Effects.send(:p, packet)
      assert env.class == :coalesce
      assert env.coalesce_key == hp_id
    end

    test "class: override beats classifier default" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:send, _, env} = Effects.send(:p, packet, class: :critical)
      assert env.class == :critical
    end

    test "coalesce_key: override beats classifier default" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:send, _, env} = Effects.send(:p, packet, coalesce_key: {:hp, :p})
      assert env.class == :coalesce
      assert env.coalesce_key == {:hp, :p}
    end
  end
end
