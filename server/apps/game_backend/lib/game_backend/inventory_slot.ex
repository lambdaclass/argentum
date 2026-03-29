defmodule GameBackend.InventorySlot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "inventory_slots" do
    belongs_to :character, GameBackend.Characters
    field :slot, :integer
    field :item_id, :integer
    field :amount, :integer, default: 1
    field :equipped, :boolean, default: false
    timestamps()
  end

  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:character_id, :slot, :item_id, :amount, :equipped])
    |> validate_required([:character_id, :slot, :item_id])
    |> validate_number(:slot, greater_than_or_equal_to: 0, less_than: 24)
    |> unique_constraint([:character_id, :slot])
  end
end
