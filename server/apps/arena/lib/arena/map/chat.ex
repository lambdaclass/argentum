defmodule Arena.Map.Chat do
  @moduledoc "Chat and yell handlers."

  alias Arena.Map.{Helpers, Visibility}
  alias AoProtocol.Server.Encoder

  @yell_range_x Application.compile_env(:arena, :aoi_range_x, 11) * 2
  @yell_range_y Application.compile_env(:arena, :aoi_range_y, 9) * 2

  def handle_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if String.starts_with?(message, "/") do
          if entity.gm do
            Arena.Map.GmCommands.dispatch_gm_command(state, char_id, entity, message)
          else
            {:noreply, state}
          end
        else
          now = System.monotonic_time(:millisecond)
          wall_now = System.system_time(:millisecond)

          cond do
            entity.muted_until > 0 and wall_now < entity.muted_until ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Estás silenciado.", font_index: 0}})}
              )
              {:noreply, state}

            now - entity.last_chat_at < chat_cooldown_ms() ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Estás hablando demasiado rápido.", font_index: 0}})}
              )
              {:noreply, state}

            true ->
              filtered_message = Arena.ChatFilter.filter(message)
              entity = %{entity | last_chat_at: now}
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              chat_raw =
                Encoder.encode(
                  {:chat_over_head,
                   %{
                     message: filtered_message,
                     char_index: entity.char_index,
                     color: 0x00FFFFFF,
                     x: entity.x,
                     y: entity.y,
                     min_display_time: 2000,
                     max_display_time: 5000
                   }}
                )

              chat_recipients =
                Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                  send(pid, {:send_raw, chat_raw})
                end)

              Arena.Metrics.inc_chat(chat_recipients)
              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_yell(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)
        wall_now = System.system_time(:millisecond)

        cond do
          entity.dead ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})}
            )

            {:noreply, state}

          entity.muted_until > 0 and wall_now < entity.muted_until ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estás silenciado.", font_index: 0}})}
            )

            {:noreply, state}

          now - entity.last_chat_at < chat_cooldown_ms() ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estás hablando demasiado rápido.", font_index: 0}})}
            )

            {:noreply, state}

          true ->
            filtered_message = Arena.ChatFilter.filter(message)
            # VB6: yelling breaks invisibility
            entity = Helpers.break_invisibility(entity, state, char_id)
            entity = %{entity | last_chat_at: now}
            players = Map.put(state.players, char_id, entity)

            yell_raw =
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

            Visibility.broadcast_range(
              %{state | players: players},
              entity.x,
              entity.y,
              @yell_range_x,
              @yell_range_y,
              fn pid ->
                send(pid, {:send_raw, yell_raw})
              end
            )

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp chat_cooldown_ms, do: Arena.Settings.get(:chat_cooldown_ms)
end
