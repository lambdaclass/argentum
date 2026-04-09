defmodule GameBackend.Repo.Migrations.CreateGuildRelations do
  use Ecto.Migration

  def change do
    create table(:guild_relations) do
      add :guild_a_id, references(:guilds, on_delete: :delete_all), null: false
      add :guild_b_id, references(:guilds, on_delete: :delete_all), null: false
      add :relation_type, :string, null: false, default: "peace"
      timestamps()
    end

    create unique_index(:guild_relations, [:guild_a_id, :guild_b_id])
  end
end
