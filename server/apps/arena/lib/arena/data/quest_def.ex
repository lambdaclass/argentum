defmodule Arena.Data.QuestDef do
  @moduledoc """
  Struct for a parsed quest definition from Quests.DAT.
  """

  defstruct [
    :id,
    :name,
    :desc,
    :desc_final,
    required_level: 0,
    limit_level: 0,
    required_class: 0,
    required_npcs: [],
    required_objs: [],
    required_spells: [],
    required_skill: 0,
    required_value: 0,
    reward_exp: 0,
    reward_gld: 0,
    reward_objs: [],
    reward_skills: [],
    repetible: false,
    pos_map: 0
  ]

  @doc "Build a QuestDef from a parsed INI section (downcased keys)."
  def from_section(id, section) do
    %__MODULE__{
      id: id,
      name: section["nombre"] || "Unknown Quest",
      desc: section["desc"] || "",
      desc_final: section["descfinal"] || "",
      required_level: parse_int(section["requiredlevel"]),
      limit_level: parse_int(section["limitlevel"]),
      required_class: parse_int(section["requiredclass"]),
      required_npcs: parse_pairs(section, "requirednpcs"),
      required_objs: parse_pairs(section, "requiredobjs"),
      required_spells: parse_int_list(section, "requiredspells"),
      required_skill: parse_int(section["requiredskill"]),
      required_value: parse_int(section["requiredvalue"]),
      reward_exp: parse_int(section["rewardexp"]),
      reward_gld: parse_int(section["rewardgld"]),
      reward_objs: parse_pairs(section, "rewardobjs"),
      reward_skills: parse_pairs(section, "rewardskills"),
      repetible: parse_bool(section["repetible"]),
      pos_map: parse_int(section["posmap"])
    }
  end

  # Parse "id-amount" pairs from "RequiredNPCs1", "RequiredNPCs2", etc.
  defp parse_pairs(section, prefix) do
    for i <- 1..20,
        val = section["#{prefix}#{i}"],
        val != nil and val != "",
        entry = parse_pair(val),
        entry != nil do
      entry
    end
  end

  defp parse_pair(str) do
    case String.split(String.trim(str), "-", parts: 2) do
      [id_str, amount_str] ->
        id = parse_int(id_str)
        amount = parse_int(amount_str)
        if id != 0, do: %{id: id, amount: amount}, else: nil

      _ ->
        nil
    end
  end

  # Parse comma-separated integer list (e.g. spell IDs)
  defp parse_int_list(section, prefix) do
    for i <- 1..20,
        val = section["#{prefix}#{i}"],
        val != nil and val != "",
        id = parse_int(val),
        id != 0 do
      id
    end
  end

  defp parse_int(nil), do: 0

  defp parse_int(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp parse_bool(nil), do: false
  defp parse_bool(val), do: parse_int(val) == 1
end
