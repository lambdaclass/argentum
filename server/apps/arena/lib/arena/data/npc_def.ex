defmodule Arena.Data.NpcDef do
  @moduledoc """
  Struct for a parsed NPC definition from npcs.dat.
  """

  defstruct [
    :id,
    :name,
    npc_type: 0,
    head: 0,
    body: 0,
    heading: 3,
    min_hp: 0,
    max_hp: 0,
    min_hit: 0,
    max_hit: 0,
    def: 0,
    magic_def: 0,
    magic_resistance: 0,
    give_exp: 0,
    give_gld: 0,
    npc_level: 0,
    movement: 1,
    hostile: false,
    attackable: false,
    poder_ataque: 0,
    poder_evasion: 0,
    intervalo_ataque: 2000,
    intervalo_movimiento: 500,
    intervalo_respawn: 60,
    veneno: 0,
    lanza_spells: 0,
    spells: [],
    loot_table: [],
    comercia: false,
    shop_items: [],
    faccion: 0
  ]

  @doc "Build an NpcDef from a parsed INI section (downcased keys)."
  def from_section(id, section) do
    %__MODULE__{
      id: id,
      name: section["name"] || "Unknown",
      npc_type: parse_int(section["npctype"]),
      head: parse_int(section["head"]),
      body: parse_int(section["body"]),
      heading: parse_int_default(section["heading"], 3),
      min_hp: parse_int(section["minhp"]),
      max_hp: parse_int(section["maxhp"]),
      min_hit: parse_int(section["minhit"]),
      max_hit: parse_int(section["maxhit"]),
      def: parse_int(section["def"]),
      magic_def: parse_int(section["magicdef"]),
      magic_resistance: parse_int(section["magicresistance"]),
      give_exp: parse_int(section["giveexp"]),
      give_gld: parse_int(section["givegld"]),
      npc_level: parse_int(section["npclvl"]),
      movement: parse_int_default(section["movement"], 1),
      hostile: parse_bool(section["hostile"]),
      attackable: parse_bool(section["attackable"]),
      poder_ataque: parse_int(section["poderataque"]),
      poder_evasion: parse_int(section["poderevasion"]),
      intervalo_ataque: parse_int_default(section["intervaloataque"], 2000),
      intervalo_movimiento: parse_int_default(section["intervalomovimiento"], 500),
      intervalo_respawn: parse_int_default(section["intervalorespawn"], 60),
      veneno: parse_int(section["veneno"]),
      lanza_spells: parse_int(section["lanzaspells"]),
      spells: parse_spells(section),
      loot_table: parse_loot_table(section),
      comercia: parse_bool(section["comercia"]),
      shop_items: parse_shop_items(section),
      faccion: parse_int(section["faccion"])
    }
  end

  # SP1..SP22: list of non-zero spell ids
  defp parse_spells(section) do
    for i <- 1..22,
        val = section["sp#{i}"],
        val != nil,
        id = parse_int(val),
        id != 0 do
      id
    end
  end

  # QuizaDropea1..QuizaDropea20: "item_id-amount" pairs
  defp parse_loot_table(section) do
    for i <- 1..20,
        val = section["quizadropea#{i}"],
        val != nil and val != "",
        entry = parse_item_amount(val),
        entry != nil do
      entry
    end
  end

  # Obj1..Obj37: "item_id-amount" pairs for shop inventory
  defp parse_shop_items(section) do
    for i <- 1..37,
        val = section["obj#{i}"],
        val != nil and val != "",
        entry = parse_item_amount(val),
        entry != nil do
      entry
    end
  end

  defp parse_item_amount(str) do
    case String.split(String.trim(str), "-", parts: 2) do
      [item_str, amount_str] ->
        item_id = parse_int(item_str)
        amount = parse_int(amount_str)
        if item_id != 0, do: %{item_id: item_id, amount: amount}, else: nil

      _ ->
        nil
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

  defp parse_int_default(nil, default), do: default

  defp parse_int_default(str, default) do
    case parse_int(str) do
      0 -> default
      val -> val
    end
  end

  defp parse_bool(nil), do: false
  defp parse_bool(val), do: parse_int(val) == 1
end
