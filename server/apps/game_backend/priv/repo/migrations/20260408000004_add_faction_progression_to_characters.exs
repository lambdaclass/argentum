defmodule GameBackend.Repo.Migrations.AddFactionProgressionToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :faction_score, :integer, default: 0, null: false
      add :faction_rank_armada, :integer, default: 0, null: false
      add :faction_rank_chaos, :integer, default: 0, null: false
      add :faction_reenlistadas, :integer, default: 0, null: false
    end
  end
end
