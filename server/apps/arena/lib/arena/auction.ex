defmodule Arena.Auction do
  @moduledoc """
  Global auction system (VB6: ModSubasta).

  Only one auction can be active at a time. A player drops an item on the
  ground near a Subastador NPC (npc_type 16), clicks the NPC to initiate,
  then sets a starting price with /OFERTAINICIAL. Other players bid with
  /OFERTAR. The auction runs for 5 minutes with auto-cancellation if no
  bids arrive within the first 2 minutes.

  The 5 % fee is charged on the final sale price.
  """

  use GenServer

  require Logger

  # Notifications are injected via :notify_fn for testability.

  # VB6: NPC type 16 = Subastador
  @npc_type_subastador 16
  # Duration in seconds
  @auction_duration_seconds 300
  # Seconds with no bids before auto-cancel
  @no_bid_cancel_seconds 120
  # Minimum bid increment
  @min_bid_increment 100
  # Fee percentage taken from seller
  @fee_percent 5
  # Seconds to set initial offer after NPC click
  @initial_offer_timeout 15
  # Time extension when bid arrives in last 60 seconds
  @last_minute_extension 30

  # ---- Public API ----

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Called when a player clicks on a Subastador NPC.
  The player must have dropped an item at their feet first.
  Returns :ok | {:error, reason}.
  """
  def initiate(server \\ __MODULE__, char_id, item_on_ground) do
    GenServer.call(server, {:initiate, char_id, item_on_ground})
  end

  @doc """
  Player sets initial offer price (/OFERTAINICIAL amount).
  """
  def set_initial_offer(server \\ __MODULE__, char_id, amount) do
    GenServer.call(server, {:set_initial_offer, char_id, amount})
  end

  @doc """
  Player places a bid (/OFERTAR amount).
  """
  def place_bid(server \\ __MODULE__, char_id, amount) do
    GenServer.call(server, {:place_bid, char_id, amount})
  end

  @doc """
  Player requests auction info (/SUBASTA).
  """
  def get_info(server \\ __MODULE__, char_id) do
    GenServer.call(server, {:get_info, char_id})
  end

  @doc """
  Returns current auction state (for testing).
  """
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc "NPC type constant for Subastador."
  def npc_type_subastador, do: @npc_type_subastador

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    notify_fn = Keyword.get(opts, :notify_fn, &default_notify/2)

    {:ok,
     %{
       active: false,
       pending: false,
       item_id: nil,
       item_amount: nil,
       initial_offer: nil,
       best_offer: 0,
       seller_id: nil,
       buyer_id: nil,
       had_bid: false,
       time_remaining: 0,
       possible_cancel: false,
       timer_ref: nil,
       initiate_timer_ref: nil,
       notify_fn: notify_fn
     }}
  end

  @impl true
  def handle_call({:initiate, char_id, item_on_ground}, _from, state) do
    cond do
      state.pending and state.seller_id == char_id and not state.active ->
        # Already pending, remind about timeout
        {:reply, {:error, :already_initiating}, state}

      state.active ->
        {:reply, {:error, :auction_in_progress}, state}

      state.pending ->
        {:reply, {:error, :auction_in_progress}, state}

      item_on_ground == nil ->
        {:reply, {:error, :no_item}, state}

      true ->
        # Cancel any previous initiate timer
        if state.initiate_timer_ref, do: Process.cancel_timer(state.initiate_timer_ref)

        timer_ref = Process.send_after(self(), {:initiate_timeout, char_id}, @initial_offer_timeout * 1_000)

        new_state = %{
          state
          | pending: true,
            seller_id: char_id,
            item_id: item_on_ground.item_id,
            item_amount: item_on_ground.amount,
            initiate_timer_ref: timer_ref
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:set_initial_offer, char_id, amount}, _from, state) do
    cond do
      not state.pending ->
        {:reply, {:error, :not_initiating}, state}

      state.active ->
        {:reply, {:error, :auction_in_progress}, state}

      state.seller_id != char_id ->
        {:reply, {:error, :not_seller}, state}

      amount <= 0 ->
        {:reply, {:error, :invalid_amount}, state}

      true ->
        if state.initiate_timer_ref, do: Process.cancel_timer(state.initiate_timer_ref)

        # Start the auction timer (ticks every second)
        timer_ref = Process.send_after(self(), :tick, 1_000)

        new_state = %{
          state
          | active: true,
            pending: false,
            initial_offer: amount,
            best_offer: 0,
            buyer_id: nil,
            had_bid: false,
            time_remaining: @auction_duration_seconds,
            possible_cancel: false,
            timer_ref: timer_ref,
            initiate_timer_ref: nil
        }

        broadcast(new_state, {:auction_started, char_id, state.item_id, state.item_amount, amount})

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:place_bid, char_id, amount}, _from, state) do
    min_bid =
      if state.had_bid do
        state.best_offer + @min_bid_increment
      else
        (state.initial_offer || 0) + @min_bid_increment
      end

    cond do
      not state.active ->
        {:reply, {:error, :no_auction}, state}

      char_id == state.seller_id ->
        {:reply, {:error, :self_bid}, state}

      amount < min_bid ->
        {:reply, {:error, :bid_too_low, min_bid}, state}

      true ->
        # Return gold to previous bidder
        previous_buyer = if state.had_bid, do: state.buyer_id, else: nil
        previous_amount = if state.had_bid, do: state.best_offer, else: 0

        # Extend time if in last 60 seconds
        {time_remaining, extended} =
          if state.time_remaining < 60 do
            {state.time_remaining + @last_minute_extension, true}
          else
            {state.time_remaining, false}
          end

        new_state = %{
          state
          | best_offer: amount,
            buyer_id: char_id,
            had_bid: true,
            possible_cancel: false,
            time_remaining: time_remaining
        }

        broadcast(new_state, {:bid_placed, char_id, amount, extended})

        {:reply,
         {:ok,
          %{
            previous_buyer: previous_buyer,
            previous_amount: previous_amount,
            extended: extended
          }}, new_state}
    end
  end

  @impl true
  def handle_call({:get_info, _char_id}, _from, state) do
    if state.active do
      info = %{
        seller_id: state.seller_id,
        item_id: state.item_id,
        item_amount: state.item_amount,
        initial_offer: state.initial_offer,
        best_offer: state.best_offer,
        had_bid: state.had_bid,
        buyer_id: state.buyer_id,
        time_remaining: state.time_remaining
      }

      {:reply, {:ok, info}, state}
    else
      {:reply, {:error, :no_auction}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if not state.active do
      {:noreply, state}
    else
      new_time = state.time_remaining - 1

      cond do
        # Auto-cancel: 2 minutes passed (time = 180 means 120s elapsed) with no bids
        new_time == @auction_duration_seconds - @no_bid_cancel_seconds and not state.had_bid ->
          broadcast(state, :auction_cancelled_no_bids)
          new_state = do_cancel_auction(state)
          {:noreply, new_state}

        # Warning at 1 minute mark with no bids
        new_time == @auction_duration_seconds - 60 and not state.had_bid ->
          broadcast(state, {:time_warning_no_bids, 4})
          timer_ref = Process.send_after(self(), :tick, 1_000)
          {:noreply, %{state | time_remaining: new_time, possible_cancel: true, timer_ref: timer_ref}}

        # Time announcements
        new_time in [240, 180, 120, 60] and state.had_bid ->
          minutes = div(new_time, 60)
          broadcast(state, {:time_warning, minutes})
          timer_ref = Process.send_after(self(), :tick, 1_000)
          {:noreply, %{state | time_remaining: new_time, timer_ref: timer_ref}}

        # Auction ended
        new_time <= 0 ->
          broadcast(state, {:auction_won, state.buyer_id})
          new_state = do_finalize_auction(state)
          {:noreply, new_state}

        # Normal tick
        true ->
          timer_ref = Process.send_after(self(), :tick, 1_000)
          {:noreply, %{state | time_remaining: new_time, timer_ref: timer_ref}}
      end
    end
  end

  @impl true
  def handle_info({:initiate_timeout, char_id}, state) do
    if state.pending and state.seller_id == char_id and not state.active do
      broadcast(state, {:initiate_timeout, char_id, state.item_id, state.item_amount})
      {:noreply, do_reset(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Internal ----

  defp do_finalize_auction(state) do
    fee = div(state.best_offer * @fee_percent, 100)
    seller_gold = state.best_offer - fee

    state.notify_fn.(:auction_complete, %{
      seller_id: state.seller_id,
      buyer_id: state.buyer_id,
      item_id: state.item_id,
      item_amount: state.item_amount,
      seller_gold: seller_gold,
      buyer_gold_spent: state.best_offer
    })

    do_reset(state)
  end

  defp do_cancel_auction(state) do
    state.notify_fn.(:auction_cancelled, %{
      seller_id: state.seller_id,
      item_id: state.item_id,
      item_amount: state.item_amount
    })

    do_reset(state)
  end

  defp do_reset(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.initiate_timer_ref, do: Process.cancel_timer(state.initiate_timer_ref)

    %{
      state
      | active: false,
        pending: false,
        item_id: nil,
        item_amount: nil,
        initial_offer: nil,
        best_offer: 0,
        seller_id: nil,
        buyer_id: nil,
        had_bid: false,
        time_remaining: 0,
        possible_cancel: false,
        timer_ref: nil,
        initiate_timer_ref: nil
    }
  end

  defp broadcast(state, event) do
    state.notify_fn.(:broadcast, event)
  end

  defp default_notify(:broadcast, event) do
    Logger.info("[Auction] broadcast: #{inspect(event)}")
  end

  defp default_notify(type, data) do
    Logger.info("[Auction] #{type}: #{inspect(data)}")
  end
end
