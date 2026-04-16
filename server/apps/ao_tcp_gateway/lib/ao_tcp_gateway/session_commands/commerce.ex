defmodule AoTcpGateway.SessionCommands.Commerce do
  @moduledoc """
  Commerce command handlers — NPC shops, banking, player-to-player trading, and auctions.
  """

  # ---- NPC Commerce ----

  def handle_command(state, {:commerce_start, _}) do
    case Arena.Map.MapServer.open_commerce(state.map_id, state.character_id, state.target_x, state.target_y) do
      :ok -> {%{state | in_commerce: true}, []}
      _ -> {state, []}
    end
  end

  def handle_command(state, {:commerce_buy, %{slot: slot, amount: amount}})
      when state.in_commerce == true do
    Arena.Map.MapServer.commerce_buy(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  def handle_command(state, {:commerce_buy, _}) do
    {state, [{:console_msg, %{message: "No estas en un comercio.", font_index: 0}}]}
  end

  def handle_command(state, {:commerce_sell, %{slot: slot, amount: amount}})
      when state.in_commerce == true do
    Arena.Map.MapServer.commerce_sell(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  def handle_command(state, {:commerce_sell, _}) do
    {state, [{:console_msg, %{message: "No estas en un comercio.", font_index: 0}}]}
  end

  def handle_command(state, {:commerce_end, _}) do
    Arena.Map.MapServer.commerce_end(state.map_id, state.character_id)
    {%{state | in_commerce: false}, []}
  end

  # ---- Banking ----

  def handle_command(state, {:bank_start, _}) do
    case Arena.Map.MapServer.open_bank(state.map_id, state.character_id, state.target_x, state.target_y) do
      :ok -> {%{state | in_bank: true}, []}
      _ -> {state, []}
    end
  end

  def handle_command(state, {:bank_deposit, %{slot: slot, amount: amount, slot_destino: slot_destino}})
      when state.in_bank == true do
    Arena.Map.MapServer.bank_deposit(state.map_id, state.character_id, slot, amount, slot_destino)
    {state, []}
  end

  def handle_command(state, {:bank_deposit, _}) do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_extract_item, %{slot: slot, amount: amount, slot_destino: slot_destino}})
      when state.in_bank == true do
    Arena.Map.MapServer.bank_extract_item(state.map_id, state.character_id, slot, amount, slot_destino)
    {state, []}
  end

  def handle_command(state, {:bank_extract_item, _}) do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_deposit_gold, %{amount: amount}})
      when state.in_bank == true do
    Arena.Map.MapServer.bank_deposit_gold(state.map_id, state.character_id, amount)
    {state, []}
  end

  def handle_command(state, {:bank_deposit_gold, _}) do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_extract_gold, %{amount: amount}})
      when state.in_bank == true do
    Arena.Map.MapServer.bank_extract_gold(state.map_id, state.character_id, amount)
    {state, []}
  end

  def handle_command(state, {:bank_extract_gold, _}) do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_end, _}) do
    Arena.Map.MapServer.bank_end(state.map_id, state.character_id)
    {%{state | in_bank: false}, []}
  end

  # ---- User-to-user trade ----

  @trade_not_active_msg {:console_msg, %{message: "No estas en un comercio con otro jugador.", font_index: 0}}

  def handle_command(state, {:user_commerce_offer, _})
      when state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_offer, %{obj_index: obj_index, amount: amount}}) do
    case Arena.Map.MapServer.user_trade_offer(state.map_id, state.character_id, obj_index, amount) do
      {:error, :not_trading} ->
        {%{state | in_trade: false}, [@trade_not_active_msg]}
      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:user_commerce_ok, _})
      when state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_ok, _}) do
    case Arena.Map.MapServer.user_trade_accept(state.map_id, state.character_id) do
      {:error, :not_trading} ->
        {%{state | in_trade: false}, [@trade_not_active_msg]}
      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:user_commerce_reject, _})
      when state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_reject, _}) do
    Arena.Map.MapServer.user_trade_reject(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:user_commerce_end, _})
      when state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_end, _}) do
    Arena.Map.MapServer.user_trade_end(state.map_id, state.character_id)
    {state, []}
  end

  # ---- Auction ----

  def handle_command(state, {:oferta_inicial, %{amount: amount}}) do
    case Arena.Auction.set_initial_offer(state.character_id, amount) do
      :ok ->
        {state, []}

      {:error, :not_initiating} ->
        {state,
         [{:console_msg,
           %{message: "Primero tenes que hacer click sobre el subastador.", font_index: 0}}]}

      {:error, :not_seller} ->
        {state,
         [{:console_msg,
           %{
             message: "Oye amigo, tu no podes decirme cual es la oferta inicial.",
             font_index: 0
           }}]}

      {:error, :auction_in_progress} ->
        {state,
         [{:console_msg, %{message: "Ya hay una subasta en curso.", font_index: 0}}]}

      {:error, _reason} ->
        {state,
         [{:console_msg, %{message: "No se pudo iniciar la subasta.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:oferta_de_subasta, %{amount: amount}}) do
    case Arena.Auction.place_bid(state.character_id, amount) do
      {:ok, _result} ->
        {state, []}

      {:error, :no_auction} ->
        {state,
         [{:console_msg, %{message: "No hay ninguna subasta en curso.", font_index: 0}}]}

      {:error, :self_bid} ->
        {state,
         [{:console_msg,
           %{message: "No podes auto ofertar en tus subastas.", font_index: 0}}]}

      {:error, :bid_too_low, _min} ->
        {state,
         [{:console_msg,
           %{
             message:
               "Debe haber almenos una diferencia de 100 monedas a la ultima oferta!",
             font_index: 0
           }}]}

      {:error, :bid_too_low} ->
        {state,
         [{:console_msg,
           %{
             message:
               "Debe haber almenos una diferencia de 100 monedas a la ultima oferta!",
             font_index: 0
           }}]}

      {:error, _reason} ->
        {state,
         [{:console_msg, %{message: "No se pudo realizar la oferta.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:subasta_info, _}) do
    case Arena.Auction.get_info(state.character_id) do
      {:ok, info} ->
        msgs = build_auction_info_messages(info)
        {state, msgs}

      {:error, :no_auction} ->
        {state,
         [{:console_msg,
           %{
             message: "No hay ninguna subasta activa en este momento.",
             font_index: 0
           }}]}
    end
  end

  defp build_auction_info_messages(info) do
    seller_name =
      case AoSession.OnlineDirectory.lookup_by_id(info.seller_id) do
        {:ok, s} -> s.name
        _ -> "?"
      end

    base = [
      {:console_msg, %{message: "Subastador: #{seller_name}", font_index: 0}},
      {:console_msg,
       %{message: "Objeto: item ##{info.item_id} (x#{info.item_amount})", font_index: 0}}
    ]

    offer_msgs =
      if info.had_bid do
        min_next = info.best_offer + 100

        [
          {:console_msg, %{message: "Mejor oferta: #{info.best_offer}", font_index: 0}},
          {:console_msg,
           %{
             message: "Podes realizar una oferta escribiendo /OFERTAR #{min_next}",
             font_index: 0
           }}
        ]
      else
        min_next = info.initial_offer + 100

        [
          {:console_msg, %{message: "Oferta inicial: #{info.initial_offer}", font_index: 0}},
          {:console_msg,
           %{
             message: "Podes realizar una oferta escribiendo /OFERTAR #{min_next}",
             font_index: 0
           }}
        ]
      end

    time_msg =
      {:console_msg,
       %{message: "Tiempo restante de subasta: #{info.time_remaining}s", font_index: 0}}

    base ++ offer_msgs ++ [time_msg]
  end
end
