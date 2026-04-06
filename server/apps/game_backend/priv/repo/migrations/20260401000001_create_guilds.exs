defmodule GameBackend.Repo.Migrations.CreateGuilds do
  use Ecto.Migration

  def change do
    create table(:guilds) do
      add :name, :string, null: false
      add :leader_id, :integer, null: false
      add :description, :string, default: ""
      timestamps()
    end

    create unique_index(:guilds, [:name])

    create table(:guild_members) do
      add :guild_id, references(:guilds, on_delete: :delete_all), null: false
      add :char_id, :integer, null: false
      add :rank, :string, default: "member"
      timestamps()
    end

    create unique_index(:guild_members, [:guild_id, :char_id])
    create unique_index(:guild_members, [:char_id])
    create index(:guild_members, [:guild_id])
  end
end
