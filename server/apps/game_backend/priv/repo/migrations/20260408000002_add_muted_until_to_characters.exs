defmodule GameBackend.Repo.Migrations.AddMutedUntilToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :muted_until, :bigint, default: 0
    end
  end
end
