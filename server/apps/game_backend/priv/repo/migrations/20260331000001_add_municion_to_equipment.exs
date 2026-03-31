defmodule GameBackend.Repo.Migrations.AddMunicionToEquipment do
  use Ecto.Migration

  def change do
    alter table(:character_equipment) do
      add :municion, :integer
    end
  end
end
