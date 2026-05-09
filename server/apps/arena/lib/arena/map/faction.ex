defmodule Arena.Map.Faction do
  @moduledoc """
  Faction system handlers (VB6: ModFacciones).

  Public top-level handlers follow the effects contract
  `{:ok, state, [Effect.t()]}`. MapServer dispatches them via
  `Arena.Map.Effects.run_handler/2` because none of the call sites
  branch on a reply term. Internal helpers (`give_faction_rewards/6`)
  return `{entity, state, effects}` so they compose without leaking
  `{:send_raw, _}` envelopes.

  Faction-wide chat (`handle_faction_chat/3`) broadcasts the message
  to every same-faction player on this map via the standard
  `Effects.send/2` lane. Cross-map fanout for faction members is
  intentionally not handled here; it is the responsibility of
  `AoSession.OnlineDirectory.broadcast_*` callers if that surface is
  needed in the future.
  """

  alias Arena.Map.{Effects, Helpers}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_enlistador 5
  # VB6 ModFacciones.bas:31 — Public Const MAX_FACTION_ENLISTMENTS = 0
  @max_faction_enlistments 0

  @doc """
  Map a NPC's `.faccion` byte to the faction atom used on player entities.

  VB6: NpcList(i).Faccion — 3 = Real / Armada, 2 = Caos.
  """
  def npc_faccion_to_atom(3), do: :royal_army
  def npc_faccion_to_atom(2), do: :chaos_legion
  def npc_faccion_to_atom(_), do: :none

  @doc """
  Handle NPC enlistador click: enlist in a faction or rank up if already enlisted.

  VB6: Acciones.bas:290-311 — Enlistador NPC double-click dispatch
  VB6: ModFacciones.bas:33 — EnlistarArmadaReal
  VB6: ModFacciones.bas:174 — EnlistarCaos
  """
  def handle_enlistador_click(state, char_id, entity, npc_def) do
    npc_faction = npc_faccion_to_atom(npc_def.faccion)

    cond do
      entity.dead ->
        {:ok, state, [console_effect(char_id, "Estas muerto!")]}

      npc_faction == :none ->
        {:ok, state, [console_effect(char_id, "#{npc_def.name} no puede enlistarte.")]}

      entity.faction == npc_faction ->
        handle_faction_rank_up(state, char_id, entity, npc_faction)

      entity.faction != :none ->
        {:ok, state,
         [console_effect(char_id, "Ya perteneces a una faccion. Usa /RENUNCIAR primero.")]}

      # VB6 ModFacciones.bas:63-66,191-194 reject when Reenlistadas > 0
      # (MAX_FACTION_ENLISTMENTS = 0).
      entity.faction_reenlistadas > @max_faction_enlistments ->
        {:ok, state,
         [console_effect(char_id, "No puedes volver a enlistarte en una faccion.")]}

      npc_faction == :royal_army and entity.criminal ->
        {:ok, state,
         [console_effect(char_id, "Los criminales no pueden enlistarse en la Armada Real.")]}

      npc_faction == :royal_army and entity.citizens_killed > 0 ->
        {:ok, state,
         [
           console_effect(
             char_id,
             "Has asesinado ciudadanos inocentes. No puedes enlistarte en la Armada Real."
           )
         ]}

      npc_faction == :royal_army and entity.class == :thief ->
        {:ok, state,
         [console_effect(char_id, "No hay lugar para escoria en el Ejército Real.")]}

      # VB6 ModFacciones.bas:183-186 — Chaos rejects Ciudadanos; only
      # Criminals (and prior council members) may enlist.
      npc_faction == :chaos_legion and not entity.criminal ->
        {:ok, state,
         [console_effect(char_id, "Tu no eres bienvenido aqui asqueroso Ciudadano.")]}

      true ->
        ranks = GameData.faction_ranks(npc_faction)
        rank1 = List.first(ranks)

        cond do
          rank1 != nil and entity.level < rank1.required_level ->
            {:ok, state,
             [
               console_effect(
                 char_id,
                 "Necesitas nivel #{rank1.required_level} para enlistarte."
               )
             ]}

          true ->
            entity = %{entity | faction: npc_faction}
            entity = assign_rank(entity, npc_faction, 1)
            {entity, state, reward_effects} =
              give_faction_rewards(entity, state, char_id, npc_faction, 0, 1)

            players = Map.put(state.players, char_id, entity)
            new_state = %{state | players: players}

            AoSession.OnlineDirectory.update_faction(char_id, npc_faction)

            faction_name = faction_display_name(npc_faction)

            effects =
              reward_effects ++
                [console_effect(char_id, "Te has enlistado en #{faction_name}.")]

            {:ok, new_state, effects}
        end
    end
  end

  @doc """
  Rank-up logic for already-enlisted players. Called by both the enlistador
  double-click path and the /REWARD packet path.

  VB6: ModFacciones.bas:111 — RecompensaArmadaReal
  VB6: ModFacciones.bas:237 — RecompensaCaos
  VB6: Protocol.bas:4604 — HandleReward (packet entry point)
  """
  def handle_faction_rank_up(state, char_id, entity, faction) do
    current_rank = current_faction_rank(entity, faction)
    ranks = GameData.faction_ranks(faction)
    next_rank_def = Enum.find(ranks, fn r -> r.rank == current_rank + 1 end)

    cond do
      next_rank_def == nil ->
        {:ok, state, [console_effect(char_id, "Ya tienes el rango maximo.")]}

      entity.level < next_rank_def.required_level ->
        needed = next_rank_def.required_level - entity.level

        {:ok, state,
         [
           console_effect(
             char_id,
             "Te faltan #{needed} niveles para poder recibir la proxima recompensa."
           )
         ]}

      entity.faction_score < next_rank_def.required_score ->
        needed = next_rank_def.required_score - entity.faction_score

        {:ok, state,
         [
           console_effect(
             char_id,
             "Te faltan #{needed} puntos de faccion para subir de rango."
           )
         ]}

      true ->
        new_rank = next_rank_def.rank
        entity = assign_rank(entity, faction, new_rank)

        {entity, state, reward_effects} =
          give_faction_rewards(entity, state, char_id, faction, current_rank, new_rank)

        players = Map.put(state.players, char_id, entity)
        new_state = %{state | players: players}

        effects =
          reward_effects ++
            [
              console_effect(
                char_id,
                "Has ascendido al rango #{new_rank}: #{next_rank_def.title}!"
              )
            ]

        {:ok, new_state, effects}
    end
  end

  defp current_faction_rank(entity, :royal_army), do: entity.faction_rank_armada
  defp current_faction_rank(entity, :chaos_legion), do: entity.faction_rank_chaos

  defp assign_rank(entity, :royal_army, rank), do: %{entity | faction_rank_armada: rank}
  defp assign_rank(entity, :chaos_legion, rank), do: %{entity | faction_rank_chaos: rank}

  # Give faction rank rewards (items) for all ranks between old_rank and new_rank.
  #
  # Returns `{entity, state, effects}` so callers can splice the inventory
  # slot updates and console messages into their own effect list.
  #
  # VB6: ModFacciones.bas:299 — DarRecompensas
  defp give_faction_rewards(entity, state, char_id, faction, old_rank, new_rank) do
    rewards = GameData.faction_rewards(faction)

    rewards_to_give =
      Enum.filter(rewards, fn r -> r.rank > old_rank and r.rank <= new_rank end)

    Enum.reduce(rewards_to_give, {entity, state, []}, fn reward, {ent, st, eff} ->
      item_def = GameData.get_item(reward.obj_index)

      if item_def == nil do
        {ent, st, eff}
      else
        case Arena.Inventory.add_item(ent.inventory, reward.obj_index, 1) do
          {:ok, new_inv, slot} ->
            ent = %{ent | inventory: new_inv}

            slot_effect =
              Effects.send(char_id, inventory_slot_packet(new_inv, slot))

            ack_effect = console_effect(char_id, "Has recibido #{item_def.name}.")

            {ent, st, eff ++ [slot_effect, ack_effect]}

          _ ->
            no_space = console_effect(char_id, "No tienes espacio para #{item_def.name}.")
            {ent, st, eff ++ [no_space]}
        end
      end
    end)
  end

  @doc """
  Handle the enlist-faction command by finding a nearby enlistador NPC and
  delegating to `handle_enlistador_click/4`.

  VB6: Acciones.bas:290-311 — Enlistador NPC double-click dispatch
  VB6: ModFacciones.bas:33 — EnlistarArmadaReal
  VB6: ModFacciones.bas:174 — EnlistarCaos
  """
  def handle_enlist_faction(state, char_id, faction) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case find_nearby_enlistador(state, entity, faction) do
          {:ok, _npc, npc_def} ->
            handle_enlistador_click(state, char_id, entity, npc_def)

          :not_found ->
            {:ok, state,
             [
               console_effect(
                 char_id,
                 "Necesitas estar cerca de un enlistador para enlistarte."
               )
             ]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp find_nearby_enlistador(state, entity, faction) do
    expected_faccion =
      case faction do
        :royal_army -> 3
        :chaos_legion -> 2
      end

    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)

        if npc_def != nil and
             npc_def.npc_type == @npc_type_enlistador and
             npc_def.faccion == expected_faccion and
             Helpers.within_vb6_distance?(entity, npc, 5) do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end

  @doc """
  Handle the /RENUNCIAR command: leave the player's current faction.

  VB6: Protocol.bas:4820 — HandleLeaveFaction
  VB6: ModFacciones.bas:144 — ExpulsarFaccionReal
  VB6: ModFacciones.bas:155 — ExpulsarFaccionCaos
  """
  def handle_leave_faction(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.faction == :none do
          {:ok, state, [console_effect(char_id, "No perteneces a ninguna faccion.")]}
        else
          case find_nearby_enlistador(state, entity, entity.faction) do
            :not_found ->
              {:ok, state,
               [
                 console_effect(
                   char_id,
                   "Necesitas estar cerca de un enlistador de tu faccion."
                 )
               ]}

            {:ok, _npc, _npc_def} ->
              if blocked_by_aligned_guild?(char_id) do
                {:ok, state,
                 [
                   console_effect(
                     char_id,
                     "No puedes renunciar a tu faccion mientras pertenezcas a un clan alineado."
                   )
                 ]}
              else
                entity = strip_faction_items(entity)

                entity = %{
                  entity
                  | faction: :none,
                    faction_reenlistadas: entity.faction_reenlistadas + 1
                }

                players = Map.put(state.players, char_id, entity)

                AoSession.OnlineDirectory.update_faction(char_id, :none)

                slot_effects =
                  Enum.map(0..23, fn slot ->
                    Effects.send(char_id, inventory_slot_packet(entity.inventory, slot))
                  end)

                new_state = %{state | players: players}

                effects =
                  slot_effects ++
                    [
                      Effects.broadcast_character_change(entity),
                      console_effect(char_id, "Has renunciado a tu faccion.")
                    ]

                {:ok, new_state, effects}
              end
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp blocked_by_aligned_guild?(char_id) do
    case Arena.GuildServer.get_guild(char_id) do
      {:ok, guild} ->
        guild.alignment != Arena.GuildAlignment.neutral() and
          guild.alignment != 0

      :not_in_guild ->
        false
    end
  end

  # Unequip and remove all faction-exclusive items (Real/Caos flagged).
  #
  # VB6: ModFacciones.bas:357 — PerderItemsFaccionarios
  defp strip_faction_items(entity) do
    alias Arena.Data.GameData

    Enum.reduce(0..(length(entity.inventory) - 1), entity, fn slot_idx, ent ->
      case Enum.at(ent.inventory, slot_idx) do
        %{item_id: item_id, equipped: true} when item_id > 0 ->
          case GameData.get_item(item_id) do
            nil ->
              ent

            item_def ->
              if item_def.real or item_def.caos do
                inv = List.update_at(ent.inventory, slot_idx, &%{&1 | equipped: false})
                ent = %{ent | inventory: inv}

                ent =
                  if item_def.equip_slot do
                    equipment = Map.put(ent.equipment, item_def.equip_slot, nil)
                    %{ent | equipment: equipment}
                  else
                    ent
                  end

                if item_def.equip_slot == :armor do
                  %{ent | body_id: ent.base_body_id}
                else
                  ent
                end
              else
                ent
              end
          end

        _ ->
          ent
      end
    end)
  end

  @doc """
  Calculate faction score awarded for a PvP kill.

  VB6: Modulo_UsUaRiOs.bas:1862 — ContarMuerte (kill counting entry point)
  VB6: Modulo_UsUaRiOs.bas:1916 — HandleFactionScoreForKill
  VB6: Modulo_UsUaRiOs.bas:1900 — ShouldApplyFactionBonus (1.5x for cross-faction)
  VB6: Modulo_UsUaRiOs.bas:1996 — CalculateBaseFactionScore
  """
  def faction_score_for_kill(attacker, defender) do
    att_faction = attacker.faction
    def_faction = defender.faction

    cond do
      att_faction != :none and att_faction == def_faction ->
        0

      att_faction != :none and def_faction != :none and att_faction != def_faction ->
        base = faction_score_base(attacker.level, defender.level)
        min(trunc(base * 1.5), 20)

      att_faction == :royal_army and defender.criminal ->
        min(faction_score_base(attacker.level, defender.level), 20)

      (att_faction == :chaos_legion or attacker.criminal) and
        def_faction == :none and not defender.criminal ->
        min(faction_score_base(attacker.level, defender.level), 20)

      true ->
        0
    end
  end

  # Base faction score from level difference (before bonus/cap).
  #
  # VB6: Modulo_UsUaRiOs.bas:1996 — CalculateBaseFactionScore
  defp faction_score_base(att_level, def_level) do
    if att_level < def_level do
      10 + def_level - max(att_level, 0)
    else
      max(10 - (att_level - def_level), 0)
    end
  end

  @doc """
  Handle faction-wide chat message broadcast.

  Successful broadcast fans an `Effects.send/2` to every same-faction
  player on the map (including the sender, matching VB6's behaviour
  where the sender sees their own message in the faction channel).

  VB6: Protocol.bas:5211 — HandleFactionMessage
  """
  def handle_faction_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)
        wall_now = System.system_time(:millisecond)

        cond do
          entity.dead ->
            {:ok, state, []}

          entity.muted_until > 0 and wall_now < entity.muted_until ->
            {:ok, state, [console_effect(char_id, "Estás silenciado.")]}

          entity.faction == :none ->
            {:ok, state, [console_effect(char_id, "No perteneces a ninguna faccion.")]}

          now - entity.last_chat_at < chat_cooldown_ms() ->
            {:ok, state, [console_effect(char_id, "Estás hablando demasiado rápido.")]}

          true ->
            {faction_label, font_index} = faction_chat_style(entity.faction)
            chat_msg = "#{entity.name}: #{message}"

            packet =
              Encoder.encode(
                {:console_faction_message,
                 %{
                   message: chat_msg,
                   font_index: font_index,
                   faction_label: faction_label
                 }}
              )

            broadcast_effects =
              for {cid, other} <- state.players, other.faction == entity.faction do
                Effects.send(cid, packet)
              end

            entity = %{entity | last_chat_at: now}
            players = Map.put(state.players, char_id, entity)
            {:ok, %{state | players: players}, broadcast_effects}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp chat_cooldown_ms, do: Arena.Settings.get(:chat_cooldown_ms)

  defp faction_chat_style(:royal_army), do: {"MENSAJE_ARMADA", 0}
  defp faction_chat_style(:chaos_legion), do: {"MENSAJE_LEGION", 0}
  defp faction_chat_style(_), do: {"", 0}

  defp faction_display_name(:royal_army), do: "Armada Real"
  defp faction_display_name(:chaos_legion), do: "Legion del Caos"
  defp faction_display_name(_), do: "Ninguna"

  defp console_effect(char_id, message) do
    Effects.send(char_id, Encoder.encode({:console_msg, %{message: message, font_index: 0}}))
  end

  # Mirror of `Helpers.send_inventory_slot/4` packet construction (sans
  # transmission). Inlined here so reward / strip-items effects can be
  # constructed without going through the legacy `{:send_raw, _}` shim.
  defp inventory_slot_packet(inventory, slot) do
    case Enum.at(inventory, slot) do
      nil ->
        Encoder.encode({:change_inventory_slot, %{slot: slot + 1, obj_index: 0, amount: 0}})

      item ->
        item_def = GameData.get_item(item.item_id)
        valor = if item_def, do: item_def.valor, else: 0
        instance_tags = Map.get(item, :elemental_tags, 0)

        Encoder.encode(
          {:change_inventory_slot,
           %{
             slot: slot + 1,
             obj_index: item.item_id,
             amount: item.amount,
             equipped: item.equipped,
             valor: valor / 1,
             elemental_tags: instance_tags
           }}
        )
    end
  end
end
