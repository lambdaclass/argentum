defmodule Arena.Data.ItemDef do
  @moduledoc """
  Struct for a parsed item definition from obj.dat.

  Only fields needed for Phase 2 (inventory operations).
  """

  defstruct [
    :id,
    :name,
    :obj_type,
    :grh_index,
    valor: 0,
    peso: 0,
    min_hit: 0,
    max_hit: 0,
    min_def: 0,
    max_def: 0,
    min_elv: 0,
    min_ham: 0,
    min_sed: 0,
    tipo_pocion: 0,
    min_modificador: 0,
    max_modificador: 0,
    porcentaje: 0,
    stackable: false,
    equip_slot: nil
  ]

  @stackable_types [1, 5, 11, 13, 32, 33, 34]

  @equip_slots %{
    2 => :weapon,
    3 => :armor,
    16 => :shield,
    17 => :helmet
  }

  @doc "Build an ItemDef from a parsed INI section (downcased keys)."
  def from_section(id, section) do
    obj_type = parse_int(section["objtype"])

    %__MODULE__{
      id: id,
      name: section["name"] || "Unknown",
      obj_type: obj_type,
      grh_index: parse_int(section["grhindex"]),
      valor: parse_int(section["valor"]),
      peso: parse_int(section["peso"]),
      min_hit: parse_int(section["minhit"]),
      max_hit: parse_int(section["maxhit"]),
      min_def: parse_int(section["mindef"]),
      max_def: parse_int(section["maxdef"]),
      min_elv: parse_int(section["minelv"]),
      min_ham: parse_int(section["minham"]),
      min_sed: parse_int(section["minsed"]),
      tipo_pocion: parse_int(section["tipopocion"]),
      min_modificador: parse_int(section["minmodificador"]),
      max_modificador: parse_int(section["maxmodificador"]),
      porcentaje: parse_int(section["porcentaje"]),
      stackable: obj_type in @stackable_types,
      equip_slot: Map.get(@equip_slots, obj_type)
    }
  end

  defp parse_int(nil), do: 0

  defp parse_int(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end
end
