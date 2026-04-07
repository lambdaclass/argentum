defmodule GameBackend.Repo.Migrations.AddBannedUntilToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :banned_until, :utc_datetime, default: nil
    end
  end
end
