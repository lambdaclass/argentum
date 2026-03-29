defmodule Arena.Data.IniParser do
  @moduledoc """
  Parses VB6-style .dat/.ini files into `%{section => %{key => value}}`.

  Format:
    [SectionName]
    Key=Value
    ' comment lines (VB6 convention)
  """

  @doc """
  Parse a file at the given path.
  Returns `{:ok, %{section => %{key => value}}}` or `{:error, reason}`.
  All keys are downcased. Values are kept as strings.
  """
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parse INI content string into sections map."
  def parse(content) do
    content
    |> String.replace("\r", "")
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {sections, current_section} ->
      line = String.trim(line)

      cond do
        # Empty line or comment
        line == "" or String.starts_with?(line, "'") ->
          {sections, current_section}

        # Section header
        String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
          section = line |> String.slice(1..-2//1) |> String.trim()
          {Map.put_new(sections, section, %{}), section}

        # Key=Value (strip inline comments)
        current_section != nil and String.contains?(line, "=") ->
          {key, value} = split_kv(line)
          sections = update_in(sections, [current_section], &Map.put(&1, key, value))
          {sections, current_section}

        true ->
          {sections, current_section}
      end
    end)
    |> elem(0)
  end

  defp split_kv(line) do
    [key | rest] = String.split(line, "=", parts: 2)
    value = Enum.join(rest, "=")
    # Strip inline VB6 comments (single quote after value)
    value =
      case String.split(value, "'", parts: 2) do
        [v, _comment] -> String.trim(v)
        [v] -> String.trim(v)
      end

    {String.downcase(String.trim(key)), value}
  end
end
