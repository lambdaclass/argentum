defmodule GameBackend.Repo.Migrations.AddSessionToken do
  use Ecto.Migration

  def up do
    alter table(:characters) do
      add :session_token, :string
    end

    create index(:characters, [:session_token])

    flush()

    # Backfill existing characters with random session tokens.
    # Uses Elixir to generate tokens to avoid pgcrypto dependency.
    repo().query!("SELECT id FROM characters WHERE session_token IS NULL")
    |> Map.get(:rows)
    |> Enum.each(fn [id] ->
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      repo().query!("UPDATE characters SET session_token = $1 WHERE id = $2", [token, id])
    end)
  end

  def down do
    drop index(:characters, [:session_token])

    alter table(:characters) do
      remove :session_token
    end
  end
end
