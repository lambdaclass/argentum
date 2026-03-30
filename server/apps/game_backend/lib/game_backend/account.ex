defmodule GameBackend.Account do
  use Ecto.Schema
  import Ecto.Changeset
  alias GameBackend.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "accounts" do
    field :username, :string
    field :password_hash, :string
    has_many :characters, GameBackend.Characters, foreign_key: :account_id
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

  defp changeset(account, attrs) do
    account
    |> cast(attrs, [:username, :password_hash])
    |> validate_required([:username, :password_hash])
    |> validate_length(:username, min: 3, max: 30)
    |> unique_constraint(:username)
  end
end
