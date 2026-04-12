defmodule AoTcpGateway.BrowserApi do
  @moduledoc false

  import Plug.Conn

  alias Arena.CharacterCreation
  alias GameBackend.Account
  alias GameBackend.Characters
  alias GameBackend.Repo

  @session_key :browser_account_id
  @max_ranking_limit 100

  @class_labels %{
    "mago" => "Mago",
    "clerigo" => "Clérigo",
    "paladin" => "Paladín",
    "cazador" => "Cazador",
    "trabajador" => "Trabajador",
    "guerrero" => "Guerrero",
    "ladron" => "Ladrón",
    "bandido" => "Bandido",
    "asesino" => "Asesino",
    "druida" => "Druida",
    "bardo" => "Bardo",
    "pirata" => "Pirata"
  }

  @race_labels %{
    "humano" => "Humano",
    "elfo" => "Elfo",
    "elfo_oscuro" => "Elfo Oscuro",
    "enano" => "Enano",
    "gnomo" => "Gnomo",
    "orco" => "Orco"
  }

  @gender_labels %{
    "male" => "Hombre",
    "female" => "Mujer"
  }

  @home_city_labels %{
    "ullathorpe" => "Ullathorpe",
    "nix" => "Nix",
    "banderbill" => "Banderbill",
    "lindos" => "Lindos",
    "arghal" => "Arghal",
    "arkhein" => "Arkhein",
    "forgat" => "Forgat",
    "eldoria" => "Eldoria",
    "penthar" => "Penthar"
  }

  def session(conn) do
    case current_account(conn) do
      nil ->
        json(conn, 200, %{authenticated: false, account: nil})

      account ->
        json(conn, 200, %{authenticated: true, account: account_payload(account)})
    end
  end

  def register(conn, params) do
    with {:ok, username} <- required_string(params, "username", 3),
         {:ok, password} <- required_string(params, "password", 1),
         nil <- Account.get_by_username(username) do
      case Account.create(username, password) do
        {:ok, account} ->
          conn
          |> put_session(@session_key, account.id)
          |> json(201, %{account: account_payload(account)})

        {:error, changeset} ->
          json_error(conn, 422, changeset_error_message(changeset, "Could not create account."))
      end
    else
      {:error, reason} -> json_error(conn, 422, reason)
      _account -> json_error(conn, 409, "Account name already taken.")
    end
  end

  def login(conn, params) do
    with {:ok, username} <- required_string(params, "username", 3),
         {:ok, password} <- required_string(params, "password", 1) do
      case Account.get_by_username(username) do
        nil ->
          json_error(conn, 401, "Wrong username or password.")

        account ->
          if Account.verify_password(account, password) do
            conn
            |> put_session(@session_key, account.id)
            |> json(200, %{account: account_payload(account)})
          else
            json_error(conn, 401, "Wrong username or password.")
          end
      end
    else
      {:error, reason} -> json_error(conn, 422, reason)
    end
  end

  def logout(conn) do
    conn
    |> configure_session(drop: true)
    |> json(200, %{logout: true})
  end

  def character_options(conn) do
    json(conn, 200, CharacterCreation.browser_options())
  end

  def list_characters(conn) do
    with_account(conn, fn conn, account ->
      characters =
        account.id
        |> Characters.list_for_account()
        |> Enum.map(&character_payload/1)

      json(conn, 200, %{characters: characters})
    end)
  end

  def create_character(conn, params) do
    with_account(conn, fn conn, account ->
      with {:ok, name} <- required_string(params, "name", 3),
           {:ok, race} <- required_integer(params, "race"),
           {:ok, gender} <- required_integer(params, "gender"),
           {:ok, class_id} <- required_integer(params, "class"),
           {:ok, head} <- required_integer(params, "head"),
           {:ok, home_city} <- required_integer(params, "home_city"),
           nil <- Characters.get_by_name(name) do
        case CharacterCreation.create(%{
               name: name,
               race: race,
               gender: gender,
               class: class_id,
               head: head,
               home_city: home_city,
               account_id: account.id
             }) do
          {:ok, entity} ->
            attrs = Characters.from_entity(entity)

            case Characters.create(attrs,
                   inventory: Characters.inventory_from_entity(entity),
                   equipment: Characters.equipment_from_entity(entity),
                   skills: Characters.skills_from_entity(entity),
                   spells: Characters.spells_from_entity(entity)
                 ) do
              {:ok, character} ->
                json(conn, 201, %{character: character_payload(character)})

              {:error, changeset} ->
                json_error(conn, 422, changeset_error_message(changeset, "Could not create character."))
            end

          {:error, reason} ->
            json_error(conn, 422, creation_error_message(reason))
        end
      else
        {:error, reason} -> json_error(conn, 422, reason)
        _character -> json_error(conn, 409, "Character name already taken.")
      end
    end)
  end

  def create_character_session(conn, char_id) do
    with_account(conn, fn conn, account ->
      case Characters.get_for_account(account.id, char_id) do
        nil ->
          json_error(conn, 404, "Character not found for this account.")

        character ->
          json(conn, 200, %{
            character: character_payload(character),
            credentials: %{
              char_id: character.id,
              token: character.session_token
            }
          })
      end
    end)
  end

  def ranking(conn, params) do
    limit =
      params
      |> Map.get("limit")
      |> parse_integer()
      |> case do
        {:ok, value} when value > 0 -> min(value, @max_ranking_limit)
        _ -> 50
      end

    entries =
      limit
      |> Characters.general_ranking()
      |> Enum.with_index(1)
      |> Enum.map(fn {character, rank} -> ranking_payload(character, rank) end)

    json(conn, 200, %{entries: entries})
  end

  def world_pack(conn) do
    json(conn, 200, Arena.ClientMapPack.manifest())
  end

  def current_account(conn) do
    case get_session(conn, @session_key) do
      account_id when is_integer(account_id) -> Repo.get(Account, account_id)
      _ -> nil
    end
  end

  defp with_account(conn, fun) do
    case current_account(conn) do
      nil -> json_error(conn, 401, "Account session required.")
      account -> fun.(conn, account)
    end
  end

  defp account_payload(account) do
    %{
      id: account.id,
      username: account.username
    }
  end

  defp character_payload(character) do
    equipment = character.equipment

    %{
      id: character.id,
      name: character.name,
      level: character.level,
      xp: character.xp,
      class: character.class,
      class_label: label_for(@class_labels, character.class),
      race: character.race,
      race_label: label_for(@race_labels, character.race),
      gender: character.gender,
      gender_label: label_for(@gender_labels, character.gender),
      home_city: character.home_city,
      home_city_label: label_for(@home_city_labels, character.home_city),
      map_id: character.map_id,
      pos_x: character.pos_x,
      pos_y: character.pos_y,
      dead: character.dead,
      criminal: character.criminal,
      gold: character.gold,
      body_id: character.body_id,
      head_id: character.head_id,
      helmet_id: if(equipment, do: equipment.helmet, else: nil),
      weapon_id: if(equipment, do: equipment.weapon, else: nil),
      shield_id: if(equipment, do: equipment.shield, else: nil),
      online: match?({:ok, _, _}, AoSession.lookup(character.id))
    }
  end

  defp ranking_payload(character, rank) do
    %{
      rank: rank,
      character:
        character_payload(character)
        |> Map.put(:kills, character.citizens_killed + character.criminals_killed)
    }
  end

  defp label_for(_labels, nil), do: nil
  defp label_for(labels, key), do: Map.get(labels, key, key)

  defp required_string(params, key, min_length) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" -> {:error, "#{humanize_key(key)} is required."}
          String.length(trimmed) < min_length -> {:error, "#{humanize_key(key)} is too short."}
          true -> {:ok, trimmed}
        end

      _ ->
        {:error, "#{humanize_key(key)} is required."}
    end
  end

  defp required_integer(params, key) do
    params
    |> Map.get(key)
    |> parse_integer()
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{humanize_key(key)} must be an integer."}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error

  defp humanize_key("home_city"), do: "Home city"
  defp humanize_key(key), do: key |> String.replace("_", " ") |> String.capitalize()

  defp creation_error_message(:name_too_short), do: "Name too short (min 3 characters)."
  defp creation_error_message(:name_too_long), do: "Name too long (max 30 characters)."
  defp creation_error_message(:name_invalid_chars), do: "Name contains invalid characters."
  defp creation_error_message(:invalid_head), do: "Selected head is not valid for that race and gender."
  defp creation_error_message({field, value}), do: "Invalid #{field}: #{inspect(value)}."
  defp creation_error_message(_reason), do: "Could not create character."

  defp changeset_error_message(changeset, fallback) do
    case changeset.errors do
      [{field, {message, _opts}} | _] ->
        "#{humanize_field(field)} #{message}"

      _ ->
        fallback
    end
  end

  defp humanize_field(field) do
    field
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp json_error(conn, status, message) do
    json(conn, status, %{error: true, message: message})
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
