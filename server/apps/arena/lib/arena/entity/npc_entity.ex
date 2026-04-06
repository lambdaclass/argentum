defmodule Arena.Entity.NpcEntity do
  @moduledoc """
  Runtime state for an NPC instance on a map.
  Lives in MapServer state as npcs_live: %{instance_id => %NpcEntity{}}.
  """

  defstruct [
    :npc_id,
    :instance_id,
    :char_index,
    :x,
    :y,
    heading: 3,
    hp: 0,
    max_hp: 0,
    alive: true,
    target_id: nil,
    spawn_x: 0,
    spawn_y: 0,
    next_attack_at: -1_000_000_000_000,
    next_move_at: -1_000_000_000_000,
    next_spell_at: -1_000_000_000_000,
    respawn_at: nil,
    # Pet ownership: nil for wild NPCs, char_id for tamed pets
    owner_id: nil
  ]

  @doc "Create an NpcEntity from a definition, placing it at the given coordinates."
  def from_def(npc_def, instance_id, char_index, x, y) do
    hp =
      cond do
        npc_def.max_hp <= 0 -> 0
        npc_def.min_hp == npc_def.max_hp -> npc_def.max_hp
        true -> Enum.random(npc_def.min_hp..npc_def.max_hp)
      end

    %__MODULE__{
      npc_id: npc_def.id,
      instance_id: instance_id,
      char_index: char_index,
      x: x,
      y: y,
      heading: npc_def.heading,
      hp: hp,
      max_hp: max(hp, 1),
      spawn_x: x,
      spawn_y: y
    }
  end
end
