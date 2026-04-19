defmodule GameBackend.Account do
  use Ecto.Schema
  import Ecto.Changeset
  alias AoEntities.PlayerEntity
  alias GameBackend.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "accounts" do
    field(:username, :string)
    field(:password_hash, :string)
    field(:is_active_patron, :integer, default: 0)
    field(:banned_until, :utc_datetime)
    has_many(:characters, GameBackend.Characters, foreign_key: :account_id)
    timestamps()
  end

  @doc "Create a new account with a hashed password."
  def create(username, password) do
    %__MODULE__{}
    |> changeset(%{username: String.downcase(username), password_hash: Bcrypt.hash_pwd_salt(password)})
    |> Repo.insert()
  end

  @doc "Look up an account by username (case-insensitive)."
  def get_by_username(username) do
    Repo.get_by(__MODULE__, username: String.downcase(username))
  end

  @doc "Verify a plaintext password against a stored hash."
  def verify_password(%__MODULE__{password_hash: hash}, password) do
    Bcrypt.verify_pass(password, hash)
  end

  def verify_password(nil, _password) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Find an existing account and verify password, or create a new one.

  Returns `{:ok, account}` or `{:error, reason}`.
  """
  def get_or_create(username, password) do
    case get_by_username(username) do
      nil ->
        create(username, password)

      account ->
        if verify_password(account, password) do
          {:ok, account}
        else
          {:error, :wrong_password}
        end
    end
  end

  @doc "Ban an account until the given `DateTime`."
  def ban(account_id, %DateTime{} = until) do
    case Repo.get(__MODULE__, account_id) do
      nil ->
        {:error, :not_found}

      account ->
        account
        |> change(%{banned_until: DateTime.truncate(until, :second)})
        |> Repo.update()
    end
  end

  @doc "Remove a ban from an account."
  def unban(account_id) do
    case Repo.get(__MODULE__, account_id) do
      nil ->
        {:error, :not_found}

      account ->
        account
        |> change(%{banned_until: nil})
        |> Repo.update()
    end
  end

  @doc "Check whether an account is currently banned."
  def banned?(%__MODULE__{banned_until: nil}), do: false

  def banned?(%__MODULE__{banned_until: until}) do
    DateTime.compare(until, DateTime.utc_now()) == :gt
  end

  @doc "Map the legacy VB6 account patron integer to an online user tier atom."
  def user_tier(%__MODULE__{is_active_patron: value}) do
    PlayerEntity.normalize_user_tier(value)
  end

  def user_tier(value) do
    PlayerEntity.normalize_user_tier(value)
  end

  defp changeset(account, attrs) do
    account
    |> cast(attrs, [:username, :password_hash, :is_active_patron])
    |> validate_required([:username, :password_hash])
    |> validate_length(:username, min: 3, max: 30)
    |> unique_constraint(:username)
  end
end
