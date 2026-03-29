defmodule GameBackend.Repo.Migrations.CreateCharacters do
  use Ecto.Migration

  def change do
    create table(:characters) do
      add :name, :string, null: false
      add :account_id, :string, null: false
      add :race, :string, default: "human"
      add :class, :string, default: "warrior"
      add :gender, :string, default: "male"
      add :home_city, :string, default: "ullathorpe"

      add :level, :integer, default: 1
      add :xp, :integer, default: 0
      add :skill_points, :integer, default: 0

      add :map_id, :integer, default: 1
      add :pos_x, :integer, default: 50
      add :pos_y, :integer, default: 50
      add :heading, :string, default: "south"

      add :hp, :integer, default: 100
      add :max_hp, :integer, default: 100
      add :mana, :integer, default: 100
      add :max_mana, :integer, default: 100
      add :stamina, :integer, default: 100
      add :max_stamina, :integer, default: 100
      add :hunger, :integer, default: 100
      add :thirst, :integer, default: 100

      add :str, :integer, default: 18
      add :agi, :integer, default: 18
      add :int, :integer, default: 18
      add :con, :integer, default: 18
      add :cha, :integer, default: 18

      add :gold, :integer, default: 0
      add :bank_gold, :integer, default: 0

      add :body_id, :integer, default: 1
      add :head_id, :integer, default: 1

      add :dead, :boolean, default: false
      add :criminal, :boolean, default: false
      add :gm, :boolean, default: false

      add :skills, :map, default: %{}
      add :spells, {:array, :integer}, default: []
      add :inventory, {:array, :map}, default: []
      add :equipment, :map, default: %{}

      timestamps()
    end

    create unique_index(:characters, [:name])
    create index(:characters, [:account_id])

    create table(:bank_items) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :slot, :integer, null: false
      add :item_id, :integer, null: false
      add :amount, :integer, default: 1

      timestamps()
    end

    create unique_index(:bank_items, [:character_id, :slot])
    create index(:bank_items, [:character_id])
  end
end
