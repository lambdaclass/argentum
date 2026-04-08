defmodule Arena.Data.FactionData do
  @moduledoc """
  Parses faction rank and reward configuration from rangos_faccion.dat
  and recompensas_faccion.dat (VB6 format).

  Rank format: `<N>Rango=<NivelRequerido>-<RequiredScore>-<Titulo>`
  Reward format: `Recompensa<N>=<rank>-<ObjIndex>`

  Ranks are stored per faction. Rewards are split into two lists based
  on their position: rewards 1..NumRecompensas/2 are Chaos, the rest are Armada
  (matching VB6 layout where Caos rewards come first).
  """

  require Logger

  alias Arena.Data.IniParser

  @type rank :: %{
    rank: integer(),
    title: String.t(),
    required_level: integer(),
    required_score: integer()
  }

  @type reward :: %{
    rank: integer(),
    obj_index: integer()
  }

  @doc "Load faction ranks from rangos_faccion.dat. Returns {armada_ranks, chaos_ranks}."
  def load_ranks(dat_dir) do
    path = Path.join(dat_dir, "rangos_faccion.dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        init = Map.get(sections, "INIT", %{})
        num_ranks = parse_int(init["numrangos"])
        armada_section = Map.get(sections, "ARMADAREAL", %{})
        chaos_section = Map.get(sections, "LEGIONCAOS", %{})

        armada_ranks = parse_rank_section(armada_section, num_ranks)
        chaos_ranks = parse_rank_section(chaos_section, num_ranks)

        Logger.info("Loaded #{length(armada_ranks)} Armada ranks, #{length(chaos_ranks)} Chaos ranks")
        {armada_ranks, chaos_ranks}

      {:error, reason} ->
        Logger.warning("Could not load rangos_faccion.dat: #{inspect(reason)}. No faction ranks.")
        {[], []}
    end
  end

  @doc """
  Load faction rewards from recompensas_faccion.dat.

  VB6 layout: first half of rewards are Chaos, second half are Armada.
  Returns {armada_rewards, chaos_rewards} where each is a list of %{rank, obj_index}.
  """
  def load_rewards(dat_dir) do
    path = Path.join(dat_dir, "recompensas_faccion.dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        init = Map.get(sections, "INIT", %{})
        num_rewards = parse_int(init["numrecompensas"])
        reward_section = Map.get(sections, "RECOMPENSAS", %{})

        all_rewards =
          for i <- 1..num_rewards,
              val = reward_section["recompensa#{i}"],
              val != nil do
            parse_reward(val)
          end
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(fn r -> r.obj_index <= 1 end)

        # VB6 splits: first half = Chaos, second half = Armada
        half = div(num_rewards, 2)
        {chaos_raw, armada_raw} =
          all_rewards
          |> Enum.with_index(1)
          |> Enum.split_with(fn {_r, idx} -> idx <= half end)

        chaos_rewards = Enum.map(chaos_raw, fn {r, _} -> r end)
        armada_rewards = Enum.map(armada_raw, fn {r, _} -> r end)

        Logger.info("Loaded #{length(armada_rewards)} Armada rewards, #{length(chaos_rewards)} Chaos rewards")
        {armada_rewards, chaos_rewards}

      {:error, reason} ->
        Logger.warning("Could not load recompensas_faccion.dat: #{inspect(reason)}. No faction rewards.")
        {[], []}
    end
  end

  defp parse_rank_section(section, num_ranks) do
    for i <- 1..max(num_ranks, 0),
        val = section["#{i}rango"],
        val != nil do
      parse_rank(i, val)
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.rank)
  end

  defp parse_rank(rank_num, str) do
    case String.split(String.trim(str), "-", parts: 3) do
      [level_str, score_str, title] ->
        %{
          rank: rank_num,
          title: String.trim(title),
          required_level: parse_int(level_str),
          required_score: parse_int(score_str)
        }

      _ ->
        nil
    end
  end

  defp parse_reward(str) do
    case String.split(String.trim(str), "-", parts: 2) do
      [rank_str, obj_str] ->
        %{rank: parse_int(rank_str), obj_index: parse_int(obj_str)}

      _ ->
        nil
    end
  end

  defp parse_int(nil), do: 0

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {val, _} -> val
      :error -> 0
    end
  end
end
