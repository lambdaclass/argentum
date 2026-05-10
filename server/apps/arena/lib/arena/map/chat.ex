defmodule Arena.Map.Chat do
  @moduledoc """
  Chat and yell handlers.

  Public top-level handlers follow the effects contract
  `{:ok, state, [Effect.t()]}`. MapServer dispatches them via
  `Arena.Map.Effects.run_handler/2`.

  GM slash commands still flow through the legacy `dispatch_gm_command/4`
  surface (`Arena.Map.GmCommands` is not yet on the effects contract);
  those calls run their own side effects inline and we forward the
  resulting state with an empty effect list, so callers do not need to
  know whether a chat message took the GM-command branch or the
  chat-over-head branch.
  """

  alias Arena.Clock
  alias Arena.Map.{Effects, Visibility}
  alias AoProtocol.Server.Encoder

  @yell_range_x Application.compile_env(:arena, :aoi_range_x, 11) * 2
  @yell_range_y Application.compile_env(:arena, :aoi_range_y, 9) * 2

  def handle_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if String.starts_with?(message, "/") do
          cond do
            entity.gm ->
              bridge_gm_dispatch(state, char_id, entity, message)

            council_faction_broadcast?(entity, message) ->
              bridge_gm_dispatch(state, char_id, entity, message)

            true ->
              {:ok, state, []}
          end
        else
          now = Clock.now_ms()
          wall_now = System.system_time(:millisecond)

          cond do
            entity.muted_until > 0 and wall_now < entity.muted_until ->
              {:ok, state, [console_effect(char_id, "Estás silenciado.")]}

            now - entity.last_chat_at < chat_cooldown_ms() ->
              {:ok, state, [console_effect(char_id, "Estás hablando demasiado rápido.")]}

            true ->
              filtered_message = Arena.ChatFilter.filter(message)
              entity = %{entity | last_chat_at: now}
              players = Map.put(state.players, char_id, entity)
              new_state = %{state | players: players}

              chat_packet =
                Encoder.encode(
                  {:chat_over_head,
                   %{
                     message: filtered_message,
                     char_index: entity.char_index,
                     # VB6 Protocol.bas:1503 — entity.flags.ChatColor drives
                     # the chat-over-head colour for live players.
                     color:
                       AoEntities.PlayerEntity.chat_color_to_int(
                         Map.get(entity, :chat_color, {255, 255, 255})
                       ),
                     x: entity.x,
                     y: entity.y,
                     min_display_time: 2000,
                     max_display_time: 5000
                   }}
                )

              # Best-effort recipient count for metrics: visible AoI peers + sender.
              # (broadcast_visible_all includes origin, so we add 1.)
              recipients =
                MapSet.size(Visibility.compute_visible_ids(new_state, entity.x, entity.y, char_id)) + 1

              Arena.Metrics.inc_chat(recipients)

              effects = [Effects.broadcast_visible_all(entity.x, entity.y, chat_packet)]
              {:ok, new_state, effects}
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  def handle_yell(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = Clock.now_ms()
        wall_now = System.system_time(:millisecond)

        cond do
          entity.dead ->
            {:ok, state, [console_effect(char_id, "Estas muerto.")]}

          entity.muted_until > 0 and wall_now < entity.muted_until ->
            {:ok, state, [console_effect(char_id, "Estás silenciado.")]}

          now - entity.last_chat_at < chat_cooldown_ms() ->
            {:ok, state, [console_effect(char_id, "Estás hablando demasiado rápido.")]}

          true ->
            filtered_message = Arena.ChatFilter.filter(message)
            # VB6: yelling breaks invisibility. Append the break_invisibility
            # effects to our own list — the surrounding handler is on the
            # effects contract, so the inline `Effects.run/2` bridge that
            # used to live here is no longer needed.
            {entity, invis_effects} = Arena.Map.Helpers.break_invisibility(entity, state, char_id)
            entity = %{entity | last_chat_at: now}
            players = Map.put(state.players, char_id, entity)
            new_state = %{state | players: players}

            yell_packet =
              Encoder.encode(
                {:chat_over_head,
                 %{
                   message: filtered_message,
                   char_index: entity.char_index,
                   color: 0x00FF0000,
                   x: entity.x,
                   y: entity.y,
                   min_display_time: 3000,
                   max_display_time: 6000
                 }}
              )

            yell_effects = [
              Effects.broadcast_range(entity.x, entity.y, @yell_range_x, @yell_range_y, yell_packet)
            ]

            {:ok, new_state, invis_effects ++ yell_effects}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp chat_cooldown_ms, do: Arena.Settings.get(:chat_cooldown_ms)

  defp console_effect(char_id, message) do
    Effects.send(char_id, Encoder.encode({:console_msg, %{message: message, font_index: 0}}))
  end

  # Bridge into the still-legacy GmCommands surface. `dispatch_gm_command/4`
  # returns `{:noreply, state}` and runs side effects inline through
  # `Helpers.send_to_session/3`, so we surface a `{:ok, state, []}` to the
  # caller — the effects already happened, and there is nothing left for
  # the runner to do until GmCommands itself migrates.
  defp bridge_gm_dispatch(state, char_id, entity, message) do
    case Arena.Map.GmCommands.dispatch_gm_command(state, char_id, entity, message) do
      {:noreply, new_state} -> {:ok, new_state, []}
    end
  end

  # Drift #4 — VB6 Protocol.bas:5177-5209 allows council members to use
  # /RMSG and /CMSG when their Faccion.Status matches the target faction.
  defp council_faction_broadcast?(entity, message) do
    command =
      message
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first("")
      |> String.upcase()

    council = Map.get(entity, :council, false)

    (command == "/RMSG" and council == :royal) or
      (command == "/CMSG" and council == :chaos)
  end
end
