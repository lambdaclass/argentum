defmodule Arena.AuctionTest do
  @moduledoc """
  Tests for the global auction system (VB6: ModSubasta).
  """
  use ExUnit.Case, async: true

  alias Arena.Auction

  # Collect notifications in the test process mailbox.
  defp notify_fn do
    test_pid = self()

    fn type, data ->
      send(test_pid, {:auction_notify, type, data})
    end
  end

  defp start_auction(_ctx) do
    {:ok, pid} = Auction.start_link(name: nil, notify_fn: notify_fn())
    %{auction: pid}
  end

  defp item_on_ground, do: %{item_id: 42, amount: 1}

  describe "initiate" do
    setup [:start_auction]

    test "succeeds when no auction active and item on ground", %{auction: pid} do
      assert :ok = Auction.initiate(pid, 1, item_on_ground())
      state = Auction.get_state(pid)
      assert state.pending == true
      assert state.item_id == 42
      assert state.seller_id == 1
    end

    test "fails with :no_item when no item on ground", %{auction: pid} do
      assert {:error, :no_item} = Auction.initiate(pid, 1, nil)
    end

    test "fails with :already_initiating when same seller tries again", %{auction: pid} do
      assert :ok = Auction.initiate(pid, 1, item_on_ground())
      assert {:error, :already_initiating} = Auction.initiate(pid, 1, item_on_ground())
    end

    test "fails with :auction_in_progress when another seller tries during pending", %{
      auction: pid
    } do
      assert :ok = Auction.initiate(pid, 1, item_on_ground())
      assert {:error, :auction_in_progress} = Auction.initiate(pid, 2, item_on_ground())
    end

    test "fails with :auction_in_progress when auction is active", %{auction: pid} do
      assert :ok = Auction.initiate(pid, 1, item_on_ground())
      assert :ok = Auction.set_initial_offer(pid, 1, 1000)
      assert {:error, :auction_in_progress} = Auction.initiate(pid, 2, item_on_ground())
    end
  end

  describe "set_initial_offer" do
    setup [:start_auction]

    test "starts the auction", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      assert :ok = Auction.set_initial_offer(pid, 1, 5000)

      state = Auction.get_state(pid)
      assert state.active == true
      assert state.initial_offer == 5000
      assert state.time_remaining == 300

      assert_received {:auction_notify, :broadcast,
                       {:auction_started, 1, 42, 1, 5000}}
    end

    test "fails when not initiating", %{auction: pid} do
      assert {:error, :not_initiating} = Auction.set_initial_offer(pid, 1, 5000)
    end

    test "fails when called by non-seller", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      assert {:error, :not_seller} = Auction.set_initial_offer(pid, 2, 5000)
    end

    test "fails with invalid amount", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      assert {:error, :invalid_amount} = Auction.set_initial_offer(pid, 1, 0)
      assert {:error, :invalid_amount} = Auction.set_initial_offer(pid, 1, -100)
    end
  end

  describe "place_bid" do
    setup [:start_auction]

    test "accepts valid bid", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      assert {:ok, %{previous_buyer: nil, previous_amount: 0, extended: false}} =
               Auction.place_bid(pid, 2, 1100)

      state = Auction.get_state(pid)
      assert state.best_offer == 1100
      assert state.buyer_id == 2
      assert state.had_bid == true
    end

    test "rejects self-bid", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      assert {:error, :self_bid} = Auction.place_bid(pid, 1, 1100)
    end

    test "rejects bid below minimum increment", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      # First bid must be at least initial_offer + 100 = 1100
      assert {:error, :bid_too_low, 1100} = Auction.place_bid(pid, 2, 1000)
    end

    test "rejects bid when no auction active", %{auction: pid} do
      assert {:error, :no_auction} = Auction.place_bid(pid, 2, 1100)
    end

    test "outbidding returns previous bidder info", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      {:ok, _} = Auction.place_bid(pid, 2, 1100)

      assert {:ok, %{previous_buyer: 2, previous_amount: 1100}} =
               Auction.place_bid(pid, 3, 1200)

      state = Auction.get_state(pid)
      assert state.buyer_id == 3
      assert state.best_offer == 1200
    end

    test "rejects second bid below increment over current best", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      {:ok, _} = Auction.place_bid(pid, 2, 1100)
      # Must be at least 1200
      assert {:error, :bid_too_low, 1200} = Auction.place_bid(pid, 3, 1150)
    end
  end

  describe "get_info" do
    setup [:start_auction]

    test "returns info when auction active", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 5000)

      assert {:ok, info} = Auction.get_info(pid, 2)
      assert info.seller_id == 1
      assert info.item_id == 42
      assert info.initial_offer == 5000
      assert info.had_bid == false
    end

    test "returns error when no auction", %{auction: pid} do
      assert {:error, :no_auction} = Auction.get_info(pid, 2)
    end
  end

  describe "timer - initiate timeout" do
    setup [:start_auction]

    test "resets state after initiate timeout", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())

      # The timeout is 15 seconds normally, but we can send the message directly
      send(pid, {:initiate_timeout, 1})
      # Give the GenServer a moment to process
      :timer.sleep(50)

      state = Auction.get_state(pid)
      assert state.pending == false
      assert state.seller_id == nil
    end

    test "timeout is ignored if seller changed", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 5000)

      # This message refers to the old pending state, should be ignored
      send(pid, {:initiate_timeout, 1})
      :timer.sleep(50)

      state = Auction.get_state(pid)
      assert state.active == true
    end
  end

  describe "timer - auction tick" do
    setup [:start_auction]

    test "auction finishes after time runs out with a bid", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)
      {:ok, _} = Auction.place_bid(pid, 2, 1100)

      # Manually set time to 1 and tick to trigger finalization
      # We need to manipulate internal state - use :sys.replace_state
      :sys.replace_state(pid, fn state ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
        %{state | time_remaining: 1, timer_ref: nil}
      end)

      send(pid, :tick)
      :timer.sleep(50)

      # Should have received auction_complete notification
      assert_received {:auction_notify, :broadcast, {:auction_won, 2}}

      assert_received {:auction_notify, :auction_complete,
                       %{
                         seller_id: 1,
                         buyer_id: 2,
                         item_id: 42,
                         seller_gold: seller_gold,
                         buyer_gold_spent: 1100
                       }}

      # 5% fee: 1100 * 5 / 100 = 55, seller gets 1045
      assert seller_gold == 1045

      state = Auction.get_state(pid)
      assert state.active == false
    end

    test "auction cancels after 2 minutes with no bids", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      # Set time to the cancel threshold (300 - 120 = 180) and tick
      :sys.replace_state(pid, fn state ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
        %{state | time_remaining: 181, timer_ref: nil}
      end)

      send(pid, :tick)
      :timer.sleep(50)

      assert_received {:auction_notify, :broadcast, :auction_cancelled_no_bids}

      assert_received {:auction_notify, :auction_cancelled,
                       %{seller_id: 1, item_id: 42, item_amount: 1}}

      state = Auction.get_state(pid)
      assert state.active == false
    end

    test "bid in last 60 seconds extends time", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      # Set time remaining to 30 seconds
      :sys.replace_state(pid, fn state ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
        %{state | time_remaining: 30, timer_ref: nil}
      end)

      {:ok, %{extended: true}} = Auction.place_bid(pid, 2, 1100)

      state = Auction.get_state(pid)
      # 30 + 30 = 60
      assert state.time_remaining == 60
    end

    test "bid after 60 seconds does not extend time", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)

      # Time remaining is 300 (just started) - well above 60
      {:ok, %{extended: false}} = Auction.place_bid(pid, 2, 1100)

      state = Auction.get_state(pid)
      assert state.time_remaining == 300
    end
  end

  describe "fee calculation" do
    setup [:start_auction]

    test "5% fee is deducted from seller payment", %{auction: pid} do
      :ok = Auction.initiate(pid, 1, item_on_ground())
      :ok = Auction.set_initial_offer(pid, 1, 1000)
      {:ok, _} = Auction.place_bid(pid, 2, 10_000)

      :sys.replace_state(pid, fn state ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
        %{state | time_remaining: 1, timer_ref: nil}
      end)

      send(pid, :tick)
      :timer.sleep(50)

      assert_received {:auction_notify, :auction_complete,
                       %{seller_gold: 9500, buyer_gold_spent: 10_000}}
    end
  end
end
