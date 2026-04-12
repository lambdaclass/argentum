defmodule Arena.Data.SpellDef do
  @moduledoc """
  Struct for a parsed spell definition from hechizos.dat.
  """

  import Bitwise, only: [band: 2]

  defstruct [
    :id,
    :name,
    tipo: 0,
    target: 0,
    min_hp: 0,
    max_hp: 0,
    mana_required: 0,
    sta_required: 0,
    min_skill: 0,
    fx_grh: 0,
    wav: 0,
    icon_index: 0,
    loops: 0,
    sube_hp: 0,
    sanacion: false,
    paraliza: false,
    envenena: false,
    cura_veneno: false,
    invisibilidad: false,
    revivir: false,
    inmoviliza: false,
    sube_fu: 0,
    min_fu: 0,
    max_fu: 0,
    sube_ag: 0,
    min_ag: 0,
    max_ag: 0,
    sube_mana: 0,
    min_mana: 0,
    max_mana: 0,
    sube_sta: 0,
    min_sta: 0,
    max_sta: 0,
    duration: 0,
    invoca: 0,
    work_on_dead: false,
    area_afecta: 0,
    area_radio: 0,
    max_level_casteable: 0,
    need_staff: false,
    staff_afecta: 0,
    cooldown: 2,
    requirement_mask: 0,
    require_weapon_type: 0,
    target_effect_type: 0,
    remove_invisibility: false
  ]

  @doc "Build a SpellDef from a parsed INI section (downcased keys)."
  def from_section(id, section) do
    %__MODULE__{
      id: id,
      name: section["nombre"] || "Unknown",
      tipo: parse_int(section["tipo"]),
      target: parse_int(section["target"]),
      min_hp: parse_int(section["minhp"]),
      max_hp: parse_int(section["maxhp"]),
      mana_required: parse_int(section["manarequerido"]),
      sta_required: parse_int(section["starequerido"]),
      min_skill: parse_int(section["minskill"]),
      fx_grh: parse_int(section["fxgrh"]),
      wav: parse_int(section["wav"]),
      icon_index: parse_int(section["iconoindex"]),
      loops: parse_int(section["loops"]),
      sube_hp: parse_int(section["subehp"]),
      sanacion: parse_bool(section["sanacion"]),
      paraliza: parse_bool(section["paraliza"]),
      envenena: parse_bool(section["envenena"]),
      cura_veneno: parse_bool(section["curaveneno"]),
      invisibilidad: parse_bool(section["invisibilidad"]),
      revivir: parse_bool(section["revivir"]),
      inmoviliza: parse_bool(section["inmoviliza"]),
      sube_fu: parse_int(section["subefu"]),
      min_fu: parse_int(section["minfu"]),
      max_fu: parse_int(section["maxfu"]),
      sube_ag: parse_int(section["subeag"]),
      min_ag: parse_int(section["minag"]),
      max_ag: parse_int(section["maxag"]),
      sube_mana: parse_int(section["subemana"]),
      min_mana: parse_int(section["minmana"]),
      max_mana: parse_int(section["maxmana"]),
      sube_sta: parse_int(section["subesta"]),
      min_sta: parse_int(section["minsta"]),
      max_sta: parse_int(section["maxsta"]),
      duration: parse_int(section["duration"]),
      invoca: parse_int(section["invoca"]),
      work_on_dead: parse_bool(section["workondead"]),
      area_afecta: parse_int(section["areaafecta"]),
      area_radio: parse_int(section["arearadio"]),
      max_level_casteable: parse_int(section["maxlevelcasteable"]),
      need_staff: parse_bool(section["needstaff"]),
      staff_afecta: parse_int(section["staffafecta"]),
      cooldown: parse_cooldown(section["cooldown"]),
      requirement_mask: parse_int(section["req"]),
      require_weapon_type: parse_int(section["requireweapontype"]),
      target_effect_type: parse_int(section["targeteffecttype"]),
      remove_invisibility: band(parse_int(section["effects"]), 32768) != 0
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

  defp parse_bool(nil), do: false
  defp parse_bool(val), do: parse_int(val) == 1

  # VB6 default spell cooldown is 2 seconds
  defp parse_cooldown(nil), do: 2

  defp parse_cooldown(val) do
    v = parse_int(val)
    if v > 0, do: v, else: 2
  end
end
