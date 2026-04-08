defmodule GameBackend.Repo.Migrations.AddCriminalsKilledToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :criminals_killed, :integer, default: 0, null: false
    end
  end
end
