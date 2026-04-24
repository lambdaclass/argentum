defmodule AoSession.EgressTest do
  use ExUnit.Case, async: true

  alias AoSession.{Egress, Outbound}

  defp enq!(state, out) do
    {:ok, state} = Egress.push(state, out)
    state
  end

  describe "critical flow" do
    test "delivers critical packets in FIFO order" do
      s =
        Egress.new(:s1)
        |> enq!(Outbound.critical(<<1>>))
        |> enq!(Outbound.critical(<<2>>))
        |> enq!(Outbound.critical(<<3>>))

      {bins, s} = Egress.flush(s, 10)
      assert bins == [<<1>>, <<2>>, <<3>>]
      assert Egress.empty?(s)
    end

    test "overflow triggers disconnect signal with state preserved" do
      s = Egress.new(:s1, %{critical_max: 2})
      s = enq!(s, Outbound.critical(<<1>>))
      s = enq!(s, Outbound.critical(<<2>>))

      assert {:disconnect, :critical_overflow, ^s} =
               Egress.push(s, Outbound.critical(<<3>>))
    end
  end

  describe "lossy flow" do
    test "drops oldest when lossy queue is full" do
      s = Egress.new(:s1, %{lossy_max: 2})
      s = enq!(s, Outbound.lossy(<<1>>))
      s = enq!(s, Outbound.lossy(<<2>>))
      s = enq!(s, Outbound.lossy(<<3>>))

      {bins, _} = Egress.flush(s, 10)
      assert bins == [<<2>>, <<3>>]
      assert s.dropped_lossy == 1
    end

    test "tracks bytes after drop-oldest" do
      s = Egress.new(:s1, %{lossy_max: 1})
      s = enq!(s, Outbound.lossy(<<0, 0, 0, 0>>))
      s = enq!(s, Outbound.lossy(<<1>>))
      assert s.queued_bytes == 1
    end
  end

  describe "coalesce flow" do
    test "latest payload wins per key" do
      s = Egress.new(:s1)
      s = enq!(s, Outbound.coalesce(<<10>>, {:hp, 1}))
      s = enq!(s, Outbound.coalesce(<<20>>, {:hp, 1}))
      s = enq!(s, Outbound.coalesce(<<30>>, {:hp, 1}))

      assert s.dropped_coalesce_replaced == 2
      {bins, _} = Egress.flush(s, 10)
      assert bins == [<<30>>]
    end

    test "different keys keep separate slots, oldest-update-first flush order" do
      s = Egress.new(:s1)
      s = enq!(s, Outbound.coalesce(<<1>>, :a))
      s = enq!(s, Outbound.coalesce(<<2>>, :b))
      s = enq!(s, Outbound.coalesce(<<99>>, :a))

      {bins, _} = Egress.flush(s, 10)
      assert bins == [<<99>>, <<2>>]
    end

    test "byte accounting on replacement" do
      s = Egress.new(:s1)
      s = enq!(s, Outbound.coalesce(<<0, 0, 0, 0, 0>>, :k))
      s = enq!(s, Outbound.coalesce(<<1>>, :k))
      assert s.queued_bytes == 1
    end
  end

  describe "flush ordering across classes" do
    test "critical → coalesce → lossy" do
      s =
        Egress.new(:s1)
        |> enq!(Outbound.lossy(<<?L>>))
        |> enq!(Outbound.coalesce(<<?C>>, :k))
        |> enq!(Outbound.critical(<<?X>>))

      {bins, _} = Egress.flush(s, 10)
      assert bins == [<<?X>>, <<?C>>, <<?L>>]
    end

    test "flush respects max_packets limit" do
      s =
        Egress.new(:s1)
        |> enq!(Outbound.critical(<<1>>))
        |> enq!(Outbound.critical(<<2>>))
        |> enq!(Outbound.critical(<<3>>))

      {bins, s} = Egress.flush(s, 2)
      assert bins == [<<1>>, <<2>>]
      assert s.critical_depth == 1
    end
  end

  describe "pressure_level/1" do
    test "ok on fresh state" do
      assert Egress.pressure_level(Egress.new(:s1)) == :ok
    end

    test "warn when soft byte budget crossed" do
      s = Egress.new(:s1, %{soft_bytes: 10, hard_bytes: 100})
      s = enq!(s, Outbound.lossy(:binary.copy(<<0>>, 20)))
      assert Egress.pressure_level(s) == :warn
    end

    test "high when hard byte budget crossed" do
      s = Egress.new(:s1, %{soft_bytes: 10, hard_bytes: 50})
      s = enq!(s, Outbound.critical(:binary.copy(<<0>>, 60)))
      assert Egress.pressure_level(s) == :high
    end

    test "critical when critical-queue depth approaches max" do
      s = Egress.new(:s1, %{critical_max: 10})

      s =
        Enum.reduce(1..9, s, fn _, acc ->
          enq!(acc, Outbound.critical(<<0>>))
        end)

      assert Egress.pressure_level(s) == :critical
    end
  end

  describe "producer API" do
    test "enqueue/2 sends {:egress, outbound} to the given pid" do
      assert :ok = Egress.enqueue(self(), Outbound.lossy(<<9>>))
      assert_receive {:egress, %Outbound{class: :lossy, payload: <<9>>}}
    end

    test "enqueue_many/2 delivers all envelopes in order" do
      outs = [Outbound.critical(<<1>>), Outbound.lossy(<<2>>), Outbound.coalesce(<<3>>, :k)]
      :ok = Egress.enqueue_many(self(), outs)
      for out <- outs, do: assert_receive {:egress, ^out}
    end
  end

  describe "byte accounting" do
    test "stays non-negative across all ops" do
      s =
        Egress.new(:s1)
        |> enq!(Outbound.critical(<<1, 2, 3>>))
        |> enq!(Outbound.lossy(<<4, 5>>))
        |> enq!(Outbound.coalesce(<<6>>, :k))

      assert s.queued_bytes == 6
      {_, s} = Egress.flush(s, 10)
      assert s.queued_bytes == 0
    end
  end
end
