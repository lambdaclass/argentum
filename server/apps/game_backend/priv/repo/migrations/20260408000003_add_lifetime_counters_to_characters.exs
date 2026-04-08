defmodule GameBackend.Repo.Migrations.AddLifetimeCountersToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :npcs_killed, :integer, default: 0, null: false
      add :deaths, :integer, default: 0, null: false
      add :penalty, :integer, default: 0, null: false
      add :fishing_points, :integer, default: 0, null: false
    end
  end
end
