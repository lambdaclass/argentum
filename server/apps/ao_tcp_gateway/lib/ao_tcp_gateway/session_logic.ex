defmodule AoTcpGateway.SessionLogic do
  @moduledoc """
  Shared session lifecycle logic for TCP and WebSocket handlers.

  Functions operate on a session state map and return `{state, [packet_commands]}`
  where packet_commands are tuples that `AoProtocol.Server.Encoder` understands.
  Transport-specific concerns (sending bytes, framing) stay in each handler.
  """

  require Logger

  @default_map_id 1

  # ---- Login ----

  def login_existing(state, char_id, token) do
    case GameBackend.Characters.get(char_id) do
      nil ->
        {state, [{:error_msg, %{message: "Character not found."}}]}

      character ->
        if GameBackend.Characters.valid_token?(character, token) do
          do_login(state, character.account_id, character)
        else
          Logger.warning("Invalid session token for char_id #{char_id}")
          {state, [{:error_msg, %{message: "Invalid session token."}}]}
        end
    end
  end

  def login_new(state, params) do
    name = params.username
    account_id = "account_#{name}"

    if GameBackend.Characters.get_by_name(name) != nil do
      {state, [{:error_msg, %{message: "Character name already taken."}}]}
    else
      case Arena.CharacterCreation.create(%{
        name: name,
        race: params.race,
        gender: params.gender,
        class: params.class,
        head: params.head,
        home_city: params.home_city,
        account_id: account_id
      }) do
        {:ok, entity} ->
          attrs = GameBackend.Characters.from_entity(entity)
          inventory = GameBackend.Characters.inventory_from_entity(entity)
          equipment = GameBackend.Characters.equipment_from_entity(entity)
          skills = GameBackend.Characters.skills_from_entity(entity)
          spells = GameBackend.Characters.spells_from_entity(entity)

          case GameBackend.Characters.create(attrs,
                 inventory: inventory,
                 equipment: equipment,
                 skills: skills,
                 spells: spells
               ) do
            {:ok, character} ->
              do_login(state, account_id, character)

            {:error, changeset} ->
              Logger.error("Failed to save new character: #{inspect(changeset)}")
              {state, [{:error_msg, %{message: "Failed to create character."}}]}
          end

        {:error, reason} ->
          {state, [{:error_msg, %{message: creation_error_message(reason)}}]}
      end
    end
  end

  defp do_login(state, account_id, character) do
    entity = GameBackend.Characters.to_entity(character)
    char_id = entity.char_id

    case AoSession.register(account_id, char_id, self()) do
      :ok ->
        {state, packets} = enter_world(state, account_id, entity)

        if state.character_id do
          token_packets =
            if is_binary(character.session_token),
              do: [{:session_token, %{char_id: char_id, token: character.session_token}}],
              else: []

          {state, packets ++ token_packets}
        else
          AoSession.unregister(char_id)
          {state, packets}
        end

      {:error, :already_connected} ->
        Logger.warning("char_id #{char_id} already connected")
        {state, [{:error_msg, %{message: "Already connected."}}]}
    end
  end

  # ---- Enter world ----

  def enter_world(state, account_id, entity) do
    map_id = entity.map_id || @default_map_id

    with :ok <- ensure_map_started(map_id),
         {:ok, char_index, all_players} <-
           Arena.Map.MapServer.enter(map_id, entity, position: {entity.x, entity.y}) do
      entity = Map.get(all_players, entity.char_id)

      Logger.info(
        "#{entity.name} entered map #{map_id} at (#{entity.x}, #{entity.y}) index=#{char_index}"
      )

      state = %{
        state
        | account_id: account_id,
          character_id: entity.char_id,
          char_index: char_index,
          map_id: map_id,
          entity: entity
      }

      packets =
        [
          {:logged, %{new_user: false}},
          {:user_index_in_server, %{user_index: 1}},
          {:change_map, %{map_id: map_id, version: 0}},
          {:user_char_index_in_server, %{char_index: char_index}},
          character_create_packet(entity),
          {:pos_update, %{x: entity.x, y: entity.y}},
          {:intervals, %{walk: 210}},
          {:update_hp, %{min_hp: entity.hp}},
          {:update_mana, %{min_mana: entity.mana}},
          {:update_stamina, %{min_sta: entity.stamina}},
          {:update_gold, %{gold: entity.gold}},
          {:update_hunger_and_thirst, %{
            max_hunger: 100,
            min_hunger: entity.hunger,
            max_thirst: 100,
            min_thirst: entity.thirst
          }}
        ] ++
          inventory_login_packets(entity) ++
          for {cid, other} <- all_players, cid != entity.char_id do
            character_create_packet(other)
          end ++
          [{:console_msg, %{message: "Welcome to Argentum Online!", font_index: 0}}]

      AoSession.OnlineDirectory.register(entity.char_id, entity.name, map_id, self())
      {state, packets}
    else
      {:error, reason} ->
        Logger.error("Failed to enter map #{map_id}: #{inspect(reason)}")
        {state, [{:error_msg, %{message: "Map not available. Try again later."}}]}
    end
  end

  # ---- Map transfer ----

  def transfer(state, dest_map, dest_x, dest_y, entity) do
    source_map = state.map_id

    with :ok <- ensure_map_started(dest_map),
         {:ok, char_index, all_players} <-
           Arena.Map.MapServer.enter(dest_map, entity, position: {dest_x, dest_y}) do
      # Destination entry succeeded — now remove from source
      Arena.Map.MapServer.leave(source_map, entity.char_id)

      entity = Map.get(all_players, entity.char_id)

      Logger.info("#{entity.name} transferred to map #{dest_map} at (#{dest_x}, #{dest_y})")

      state = %{state | map_id: dest_map, char_index: char_index, entity: entity}

      packets =
        [
          {:change_map, %{map_id: dest_map, version: 0}},
          {:user_char_index_in_server, %{char_index: char_index}},
          character_create_packet(entity),
          {:pos_update, %{x: entity.x, y: entity.y}}
        ] ++
          for {cid, other} <- all_players, cid != entity.char_id do
            character_create_packet(other)
          end

      AoSession.OnlineDirectory.update_map(state.character_id, dest_map)
      {state, packets}
    else
      {:error, reason} ->
        Logger.error("Failed to transfer to map #{dest_map}: #{inspect(reason)}")
        {state, [{:error_msg, %{message: "Destination map not available."}}]}
    end
  end

  # ---- Game commands ----

  def handle_command(state, {:walk, %{direction: direction}}) when state.character_id != nil do
    Arena.Map.MapServer.move_character(state.map_id, state.character_id, direction)
    {state, []}
  end

  def handle_command(state, {:walk, _}), do: {state, []}

  def handle_command(state, {:talk, %{message: message}}) when state.character_id != nil do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, message)
    {state, []}
  end

  def handle_command(state, {:talk, _}), do: {state, []}

  def handle_command(state, {:change_heading, %{heading: heading_int}})
      when state.character_id != nil do
    heading = int_to_heading(heading_int)
    Arena.Map.MapServer.change_heading(state.map_id, state.character_id, heading)
    {state, []}
  end

  def handle_command(state, {:change_heading, _}), do: {state, []}

  def handle_command(state, {:pick_up, _}) when state.character_id != nil do
    Arena.Map.MapServer.pick_up(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:drop, %{slot: slot, amount: amount}})
      when state.character_id != nil do
    Arena.Map.MapServer.drop_item(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  def handle_command(state, {:equip_item, %{slot: slot}}) when state.character_id != nil do
    Arena.Map.MapServer.equip_item(state.map_id, state.character_id, slot)
    {state, []}
  end

  def handle_command(state, {:use_item, %{slot: slot}}) when state.character_id != nil do
    Arena.Map.MapServer.use_item(state.map_id, state.character_id, slot)
    {state, []}
  end

  def handle_command(state, {:attack, _}), do: {state, []}

  def handle_command(state, {:request_position_update, _})
      when state.map_id != nil and state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} -> {state, [{:pos_update, %{x: entity.x, y: entity.y}}]}
      {:error, _} -> {state, []}
    end
  end

  def handle_command(state, {:request_position_update, _}), do: {state, []}

  def handle_command(state, {command_type, _}) do
    Logger.debug("Unhandled command: #{command_type}")
    {state, []}
  end

  # ---- Cleanup & autosave ----

  def cleanup(state) do
    if state.character_id && state.map_id do
      case Arena.Map.MapServer.leave(state.map_id, state.character_id) do
        {:ok, entity} ->
          try do
            attrs = GameBackend.Characters.from_entity(entity)
            inventory = GameBackend.Characters.inventory_from_entity(entity)
            equipment = GameBackend.Characters.equipment_from_entity(entity)
            skills = GameBackend.Characters.skills_from_entity(entity)
            spells = GameBackend.Characters.spells_from_entity(entity)

            case GameBackend.Characters.save_snapshot(entity.char_id, attrs,
                   inventory: inventory,
                   equipment: equipment,
                   skills: skills,
                   spells: spells
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.error("Cleanup save failed for #{entity.char_id}: #{inspect(reason)}")
            end
          rescue
            e -> Logger.error("Cleanup save error for #{entity.char_id}: #{inspect(e)}")
          end

        :not_found ->
          :ok
      end
    end

    if state.character_id do
      AoSession.OnlineDirectory.unregister(state.character_id)
      AoSession.unregister(state.character_id)
    end

    :ok
  end

  def autosave(entity) do
    Task.start(fn ->
      attrs = GameBackend.Characters.from_entity(entity)
      inventory = GameBackend.Characters.inventory_from_entity(entity)
      equipment = GameBackend.Characters.equipment_from_entity(entity)
      skills = GameBackend.Characters.skills_from_entity(entity)
      spells = GameBackend.Characters.spells_from_entity(entity)

      case GameBackend.Characters.save_snapshot(entity.char_id, attrs,
             inventory: inventory,
             equipment: equipment,
             skills: skills,
             spells: spells
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("Autosave failed for #{entity.char_id}: #{inspect(reason)}")
      end
    end)
  end

  # ---- Map readiness ----

  def ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    wait_for_map_ready(map_id, 50)
  end

  defp wait_for_map_ready(_map_id, 0), do: {:error, :map_not_ready}

  defp wait_for_map_ready(map_id, retries) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [] ->
        {:error, :map_not_found}

      _ ->
        if Arena.Map.MapServer.ready?(map_id) do
          :ok
        else
          Process.sleep(100)
          wait_for_map_ready(map_id, retries - 1)
        end
    end
  end

  # ---- Packet builders ----

  def character_create_packet(entity) do
    {:character_create,
     %{
       char_index: entity.char_index,
       body_id: entity.body_id,
       head_id: entity.head_id,
       heading: heading_to_int(entity.heading),
       x: entity.x,
       y: entity.y,
       name: entity.name || "Unknown",
       min_hp: entity.hp,
       max_hp: entity.max_hp,
       min_mana: entity.mana,
       max_mana: entity.max_mana,
       speed: entity.speeding
     }}
  end

  def inventory_login_packets(entity) do
    entity.inventory
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _idx} ->
        []

      {%{item_id: item_id, amount: amount, equipped: equipped}, idx} ->
        item_def = Arena.Data.GameData.get_item(item_id)
        valor = if item_def, do: item_def.valor, else: 0

        [
          {:change_inventory_slot,
           %{
             slot: idx + 1,
             obj_index: item_id,
             amount: amount,
             equipped: equipped,
             valor: valor / 1
           }}
        ]
    end)
  end

  # ---- Heading conversion ----

  def heading_to_int(:north), do: 1
  def heading_to_int(:east), do: 2
  def heading_to_int(:south), do: 3
  def heading_to_int(:west), do: 4
  def heading_to_int(_), do: 3

  def int_to_heading(1), do: :north
  def int_to_heading(2), do: :east
  def int_to_heading(3), do: :south
  def int_to_heading(4), do: :west
  def int_to_heading(_), do: :south

  # ---- Creation error messages ----

  defp creation_error_message(:name_too_short), do: "Name too short (min 3 characters)."
  defp creation_error_message(:name_too_long), do: "Name too long (max 30 characters)."
  defp creation_error_message(:name_invalid_chars), do: "Name contains invalid characters."
  defp creation_error_message(:name_invalid), do: "Invalid name."
  defp creation_error_message(:invalid_head), do: "Invalid head selection."
  defp creation_error_message(:name_taken), do: "Character name already taken."
  defp creation_error_message({:invalid_race, _}), do: "Invalid race."
  defp creation_error_message({:invalid_gender, _}), do: "Invalid gender."
  defp creation_error_message({:invalid_class, _}), do: "Invalid class."
  defp creation_error_message({:invalid_home_city, _}), do: "Invalid home city."
  defp creation_error_message(_), do: "Character creation failed."
end
