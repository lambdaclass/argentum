defmodule Arena.ChatFilter do
  @moduledoc "Simple word filter for chat messages."

  @blocked_words ~w(
    puto puta pelotudo pelotuda boludo boluda
    forro forra conchudo conchuda mogolico mogolica
    hijo de puta la concha mierda carajo culo
    verga pendejo pendeja cabron cabrona chingar
    maricon marica perra idiota imbecil estupido
  )

  @doc "Replace blocked words with asterisks (case-insensitive)."
  def filter(message) do
    Enum.reduce(@blocked_words, message, fn word, msg ->
      String.replace(msg, ~r/#{Regex.escape(word)}/i, String.duplicate("*", String.length(word)))
    end)
  end

  @doc "Check if a message contains any blocked words."
  def contains_blocked?(message) do
    downcased = String.downcase(message)
    Enum.any?(@blocked_words, &String.contains?(downcased, &1))
  end
end
