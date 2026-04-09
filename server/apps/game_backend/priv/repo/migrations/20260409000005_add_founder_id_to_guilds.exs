defmodule GameBackend.Repo.Migrations.AddFounderIdToGuilds do
  use Ecto.Migration

  def change do
    alter table(:guilds) do
      add :founder_id, :integer
    end

    # Backfill: set founder_id = leader_id for existing guilds
    execute "UPDATE guilds SET founder_id = leader_id WHERE founder_id IS NULL", ""
  end
end
