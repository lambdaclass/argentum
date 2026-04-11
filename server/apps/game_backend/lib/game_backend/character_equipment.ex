defmodule GameBackend.CharacterEquipment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "character_equipment" do
    belongs_to(:character, GameBackend.Characters)
    field(:weapon, :integer)
    field(:armor, :integer)
    field(:shield, :integer)
    field(:helmet, :integer)
    field(:ring, :integer)
    field(:municion, :integer)
    timestamps()
  end

  def changeset(equipment, attrs) do
    equipment
    |> cast(attrs, [:character_id, :weapon, :armor, :shield, :helmet, :ring, :municion])
    |> validate_required([:character_id])
    |> unique_constraint([:character_id])
  end
end
