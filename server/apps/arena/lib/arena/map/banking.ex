defmodule Arena.Map.Banking do
  @moduledoc "NPC banker interaction handlers (bank gold transfer)."

  alias Arena.Map.Helpers
  alias AoProtocol.Server.Encoder

  @npc_type_banquero 4

  # VB6 parity: 10 second cooldown between transfers
  @transfer_gold_cooldown_ms 10_000

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)

  @doc """
  Handle bank gold transfer to another player.

  VB6 flow (Protocol.bas:5988-6055):
  - Reads amount (Int32) and target username (String8)
  - Validates amount > 0, Stats.Banco >= amount (bank gold, not wallet)
  - Player must not be dead
  - Validates selected NPC is a Banquero (type 4) within distance 10
  - GMs are blocked from transferring gold
  - 10 second cooldown between transfers (Counters.LastTransferGold)
  - If target is online: directly adds to their Stats.Banco
  - If target is offline: calls AddOroBancoDatabase(username, amount)
  - Logs the transfer
  """
  def handle_bank_gold_transfer(state, char_id, target_name, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          # VB6: amount <= 0
          amount <= 0 ->
            {:noreply, state}

          # VB6: .flags.Muerto = 1
          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          # VB6: EsGM(UserIndex) blocks transfer
          entity.gm == true ->
            msg(state, char_id, "Los administradores no pueden transferir oro.")
            {:noreply, state}

          # VB6: Stats.Banco < Cantidad
          entity.bank_gold < amount ->
            msg(state, char_id, "No tienes suficiente oro en el banco.")
            {:noreply, state}

          true ->
            do_bank_gold_transfer(state, char_id, entity, target_name, amount)
        end

      :error ->
        {:noreply, state}
    end
  end

  def do_bank_gold_transfer(state, char_id, entity, target_name, amount) do
    # VB6: validate TargetNPC is a Banquero within distance 10
    banker_npc =
      case Helpers.resolve_selected_npc(state, entity, [@npc_type_banquero], 10) do
        {:ok, npc, _npc_def} -> npc
        :not_found -> nil
      end

    cond do
      banker_npc == nil ->
        msg(state, char_id, "Primero selecciona un banquero.")
        {:noreply, state}

      # VB6: 10s cooldown check (TicksElapsed(.Counters.LastTransferGold, nowRaw) >= 10000)
      not transfer_cooldown_elapsed?(entity) ->
        msg(state, char_id, "Espera un momento antes de transferir de nuevo.")
        {:noreply, state}

      # Cannot transfer to yourself
      target_name == entity.name ->
        msg(state, char_id, "No puedes transferirte oro a ti mismo.")
        {:noreply, state}

      true ->
        # Deduct from sender's bank gold
        new_bank_gold = entity.bank_gold - amount
        now = System.monotonic_time(:millisecond)

        entity = %{entity | bank_gold: new_bank_gold, last_transfer_gold_at: now}
        state = %{state | players: Map.put(state.players, char_id, entity)}

        # Persist the sender's new bank gold
        Arena.Map.Bank.save_bank_gold(entity.char_id, new_bank_gold)

        # Try to deliver to online target, fall back to offline DB write
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, target_id, target_info} ->
            # Target is online — add to their bank_gold via their map server
            target_map = target_info.map_id
            Arena.Map.MapServer.modify_bank_gold(target_map, target_id, amount)

          :not_found ->
            # Target is offline — persist to database
            deliver_offline_bank_gold(target_name, amount)
        end

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_bank_gold, %{bank_gold: new_bank_gold}})}
        )

        msg(state, char_id, "El envio se ha realizado con exito.")
        {:noreply, state}
    end
  end

  def transfer_cooldown_elapsed?(entity) do
    last = Map.get(entity, :last_transfer_gold_at, -1_000_000_000_000)
    now = System.monotonic_time(:millisecond)
    now - last >= @transfer_gold_cooldown_ms
  end

  def deliver_offline_bank_gold(target_name, amount) do
    # Look up the character by name and add to their bank_gold in DB
    case GameBackend.Characters.get_by_name(target_name) do
      nil ->
        :not_found

      char ->
        new_bank_gold = (char.bank_gold || 0) + amount
        GameBackend.Characters.save_snapshot(char.id, %{bank_gold: new_bank_gold})
    end
  end
end
