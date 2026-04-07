defmodule GameBackend.Repo.Migrations.AddFactionToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :faction, :string, default: "none"
      add :faction_kills_royal, :integer, default: 0
      add :faction_kills_chaos, :integer, default: 0
      add :citizens_killed, :integer, default: 0
    end
  end
end
