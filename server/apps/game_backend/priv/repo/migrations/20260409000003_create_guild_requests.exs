defmodule GameBackend.Repo.Migrations.CreateGuildRequests do
  use Ecto.Migration

  def change do
    create table(:guild_requests) do
      add :guild_id, references(:guilds, on_delete: :delete_all), null: false
      add :char_id, :integer, null: false
      add :description, :text, default: ""
      timestamps()
    end

    create unique_index(:guild_requests, [:guild_id, :char_id])
  end
end
