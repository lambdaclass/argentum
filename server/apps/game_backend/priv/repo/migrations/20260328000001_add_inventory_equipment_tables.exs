defmodule GameBackend.Repo.Migrations.AddInventoryEquipmentTables do
  use Ecto.Migration

  def change do
    create table(:inventory_slots) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :slot, :integer, null: false
      add :item_id, :integer, null: false
      add :amount, :integer, default: 1
      add :equipped, :boolean, default: false
      timestamps()
    end

    create unique_index(:inventory_slots, [:character_id, :slot])
    create index(:inventory_slots, [:character_id])

    create table(:character_equipment) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :weapon, :integer
      add :armor, :integer
      add :shield, :integer
      add :helmet, :integer
      add :ring, :integer
      timestamps()
    end

    create unique_index(:character_equipment, [:character_id])

    alter table(:characters) do
      remove :inventory
      remove :equipment
    end
  end
end
