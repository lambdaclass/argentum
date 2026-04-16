defmodule AoTcpGateway.SessionLogin do
  @moduledoc """
  Login lifecycle: account resolution, character creation, session registration.

  Extracted from SessionLogic as a pure structural refactor.
  """

  require Logger

  alias AoTcpGateway.SessionWorld

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
    password = params.session_token

    case GameBackend.Account.get_or_create(name, password) do
      {:error, :wrong_password} ->
        {state, [{:error_msg, %{message: "Wrong password."}}]}

      {:error, changeset} ->
        Logger.error("Account creation failed: #{inspect(changeset)}")
        {state, [{:error_msg, %{message: "Failed to create account."}}]}

      {:ok, account} ->
        case GameBackend.Characters.get_by_name(name) do
          %{account_id: aid} = existing when aid == account.id ->
            # Character exists and belongs to this account — log in as existing
            do_login(state, account.id, existing)

          nil ->
            create_new_character(state, account, params)

          _other ->
            {state, [{:error_msg, %{message: "Character name already taken."}}]}
        end
    end
  end

  defp create_new_character(state, account, params) do
    case Arena.CharacterCreation.create(%{
      name: params.username,
      race: params.race,
      gender: params.gender,
      class: params.class,
      head: params.head,
      home_city: params.home_city,
      account_id: account.id
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
            do_login(state, account.id, character)

          {:error, changeset} ->
            Logger.error("Failed to save new character: #{inspect(changeset)}")
            {state, [{:error_msg, %{message: "Failed to create character."}}]}
        end

      {:error, reason} ->
        {state, [{:error_msg, %{message: creation_error_message(reason)}}]}
    end
  end

  defp do_login(state, account_id, character) do
    account = GameBackend.Repo.get(GameBackend.Account, account_id)

    if account != nil and GameBackend.Account.banned?(account) do
      formatted = Calendar.strftime(account.banned_until, "%Y-%m-%d %H:%M UTC")

      {state,
       [
         {:console_msg, %{message: "Tu cuenta está baneada hasta #{formatted}.", font_index: 0}},
         {:error_msg, %{message: "Account banned."}}
       ]}
    else
      entity = GameBackend.Characters.to_entity(character)
      char_id = entity.char_id

      # Populate guild cache on the entity (one RPC per login is fine)
      entity =
        case Arena.GuildServer.get_guild(char_id) do
          {:ok, guild} -> %{entity | guild_id: guild.id, guild_level: guild.level}
          :not_in_guild -> entity
        end

      case AoSession.register(account_id, char_id, self()) do
        :ok ->
          {state, packets} = SessionWorld.enter_world(state, account_id, entity)

          if state.character_id do
            {state, packets}
          else
            AoSession.unregister(char_id)
            {state, packets}
          end

        {:error, :already_connected} ->
          Logger.warning("char_id #{char_id} already connected")
          {state, [{:error_msg, %{message: "Already connected."}}]}
      end
    end
  end

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
