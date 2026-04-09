defmodule GameBackend.Repo.Migrations.AddElementalTags do
  use Ecto.Migration

  def change do
    alter table(:inventory_slots) do
      add :elemental_tags, :integer, default: 0, null: false
    end

    alter table(:bank_items) do
      add :elemental_tags, :integer, default: 0, null: false
    end
  end
end
