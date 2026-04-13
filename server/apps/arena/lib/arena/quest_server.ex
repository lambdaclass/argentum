defmodule Arena.QuestServer do
  @moduledoc """
  Pure-function quest logic.

  All functions receive and return player entity structs — no GenServer.
  Called from Social/MapServer handlers.
  """

  alias Arena.Data.GameData

  @max_active_quests 20

  @doc "Return quest IDs available from an NPC (from its quest_numbers list) that the player hasn't completed/accepted."
  def available_quests_for_npc(entity, npc_def) do
    quest_numbers = Map.get(npc_def, :quest_numbers, [])

    Enum.filter(quest_numbers, fn quest_id ->
      quest_def = GameData.get_quest(quest_id)

      quest_def != nil and
        not already_active?(entity, quest_id) and
        (not MapSet.member?(entity.completed_quests, quest_id) or quest_def.repetible) and
        meets_requirements?(entity, quest_def)
    end)
  end

  @doc "Check if a player can accept a quest."
  def can_accept_quest?(entity, quest_def) do
    length(entity.active_quests) < @max_active_quests and
      not already_active?(entity, quest_def.id) and
      (not MapSet.member?(entity.completed_quests, quest_def.id) or quest_def.repetible) and
      meets_requirements?(entity, quest_def)
  end

  @doc "Accept a quest — add it to active_quests with initial progress."
  def accept_quest(entity, quest_def) do
    quest_state = %{
      quest_id: quest_def.id,
      npc_kills: %{},
      started_at: System.monotonic_time(:millisecond)
    }

    %{entity | active_quests: entity.active_quests ++ [quest_state]}
  end

  @doc "Abandon a quest by slot index (0-based)."
  def abandon_quest(entity, slot) when slot >= 0 and slot < length(entity.active_quests) do
    {_removed, remaining} = List.pop_at(entity.active_quests, slot)
    %{entity | active_quests: remaining}
  end

  def abandon_quest(entity, _slot), do: entity

  @doc "Record an NPC kill for quest tracking. Called from combat_handlers."
  def record_npc_kill(entity, npc_id) do
    updated_quests =
      Enum.map(entity.active_quests, fn qs ->
        quest_def = GameData.get_quest(qs.quest_id)

        if quest_def != nil and Enum.any?(quest_def.required_npcs, fn req -> req.id == npc_id end) do
          current = Map.get(qs.npc_kills, npc_id, 0)
          %{qs | npc_kills: Map.put(qs.npc_kills, npc_id, current + 1)}
        else
          qs
        end
      end)

    %{entity | active_quests: updated_quests}
  end

  @doc "Check if quest objectives are complete for a given active quest slot."
  def quest_complete?(entity, slot) when slot >= 0 and slot < length(entity.active_quests) do
    qs = Enum.at(entity.active_quests, slot)
    quest_def = GameData.get_quest(qs.quest_id)
    quest_def != nil and objectives_met?(entity, qs, quest_def)
  end

  def quest_complete?(_entity, _slot), do: false

  @doc "Complete a quest: grant rewards, remove from active, add to completed."
  def complete_quest(entity, slot) when slot >= 0 and slot < length(entity.active_quests) do
    qs = Enum.at(entity.active_quests, slot)
    quest_def = GameData.get_quest(qs.quest_id)

    if quest_def == nil or not objectives_met?(entity, qs, quest_def) do
      entity
    else
      entity = grant_rewards(entity, quest_def)
      {_removed, remaining} = List.pop_at(entity.active_quests, slot)

      %{entity | active_quests: remaining, completed_quests: MapSet.put(entity.completed_quests, quest_def.id)}
    end
  end

  def complete_quest(entity, _slot), do: entity

  @doc "Build a details map for a quest slot (for protocol encoding)."
  def build_quest_details(entity, slot) when slot >= 0 and slot < length(entity.active_quests) do
    qs = Enum.at(entity.active_quests, slot)
    quest_def = GameData.get_quest(qs.quest_id)

    if quest_def == nil do
      nil
    else
      %{
        quest_id: quest_def.id,
        name: quest_def.name,
        desc: quest_def.desc,
        required_npcs:
          Enum.map(quest_def.required_npcs, fn req ->
            killed = Map.get(qs.npc_kills, req.id, 0)
            %{id: req.id, required: req.amount, current: killed}
          end),
        required_objs: quest_def.required_objs,
        reward_exp: quest_def.reward_exp,
        reward_gld: quest_def.reward_gld,
        reward_objs: quest_def.reward_objs,
        complete: objectives_met?(entity, qs, quest_def)
      }
    end
  end

  def build_quest_details(_entity, _slot), do: nil

  @doc "Build a list of quest names/ids available from an NPC."
  def build_npc_quest_list(quest_ids) do
    Enum.map(quest_ids, fn qid ->
      quest_def = GameData.get_quest(qid)
      if quest_def, do: %{quest_id: qid, name: quest_def.name}, else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ---- Private ----

  defp already_active?(entity, quest_id) do
    Enum.any?(entity.active_quests, fn qs -> qs.quest_id == quest_id end)
  end

  defp meets_requirements?(entity, quest_def) do
    (quest_def.required_level == 0 or entity.level >= quest_def.required_level) and
      (quest_def.limit_level == 0 or entity.level <= quest_def.limit_level)
  end

  defp objectives_met?(entity, qs, quest_def) do
    npcs_ok =
      Enum.all?(quest_def.required_npcs, fn req ->
        Map.get(qs.npc_kills, req.id, 0) >= req.amount
      end)

    objs_ok =
      Enum.all?(quest_def.required_objs, fn req ->
        count_inventory_item(entity, req.id) >= req.amount
      end)

    npcs_ok and objs_ok
  end

  defp count_inventory_item(entity, item_id) do
    Enum.reduce(entity.inventory, 0, fn
      %{item_id: ^item_id, amount: amount}, acc -> acc + amount
      _, acc -> acc
    end)
  end

  defp grant_rewards(entity, quest_def) do
    entity = %{entity | xp: entity.xp + quest_def.reward_exp, gold: entity.gold + quest_def.reward_gld}

    Enum.reduce(quest_def.reward_objs, entity, fn reward, ent ->
      add_inventory_item(ent, reward.id, reward.amount)
    end)
  end

  defp add_inventory_item(entity, item_id, amount) do
    # Find first empty slot or existing stack
    case find_slot(entity.inventory, item_id) do
      {:existing, idx} ->
        slot = Enum.at(entity.inventory, idx)
        updated = %{slot | amount: slot.amount + amount}
        %{entity | inventory: List.replace_at(entity.inventory, idx, updated)}

      {:empty, idx} ->
        %{
          entity
          | inventory: List.replace_at(entity.inventory, idx, %{item_id: item_id, amount: amount, equipped: false})
        }

      :full ->
        entity
    end
  end

  defp find_slot(inventory, item_id) do
    existing =
      Enum.with_index(inventory)
      |> Enum.find(fn
        {%{item_id: ^item_id}, _idx} -> true
        _ -> false
      end)

    case existing do
      {_, idx} ->
        {:existing, idx}

      nil ->
        empty =
          Enum.with_index(inventory)
          |> Enum.find(fn {slot, _idx} -> slot == nil end)

        case empty do
          {_, idx} -> {:empty, idx}
          nil -> :full
        end
    end
  end
end
