defmodule Arena.Map.EffectsTest do
  use ExUnit.Case, async: true

  alias Arena.Map.Effects

  describe "run/2" do
    test "empty list is a no-op" do
      assert :ok = Effects.run(%{sessions: %{}}, [])
    end

    test ":send routes packet to the session pid" do
      state = %{sessions: %{42 => self()}}
      assert :ok = Effects.run(state, [{:send, 42, "hello"}])
      assert_receive {:send_raw, "hello"}
    end

    test ":send to a missing session is silently dropped" do
      state = %{sessions: %{}}
      assert :ok = Effects.run(state, [{:send, 999, "x"}])
      refute_receive _, 50
    end

    test "preserves order across multiple :send effects to the same session" do
      state = %{sessions: %{1 => self()}}
      assert :ok = Effects.run(state, [{:send, 1, "a"}, {:send, 1, "b"}, {:send, 1, "c"}])
      assert_receive {:send_raw, "a"}
      assert_receive {:send_raw, "b"}
      assert_receive {:send_raw, "c"}
    end

    test "unknown effect raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Effects.run(%{sessions: %{}}, [{:bogus, 1, 2}])
      end
    end
  end
end
