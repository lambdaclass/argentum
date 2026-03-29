defmodule GameBackend.BankItems do
  @moduledoc """
  Ecto schema for bank inventory.

  Bank lives in DB always — loaded on demand during NPC interaction,
  never part of MapServer hot state.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias GameBackend.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "bank_items" do
    field :character_id, :integer
    field :slot, :integer
    field :item_id, :integer
    field :amount, :integer, default: 1

    timestamps()
  end

  def changeset(bank_item, attrs) do
    bank_item
    |> cast(attrs, [:character_id, :slot, :item_id, :amount])
    |> validate_required([:character_id, :slot, :item_id])
    |> unique_constraint([:character_id, :slot])
  end

  @doc "Get all bank items for a character."
  def get_bank(character_id) do
    __MODULE__
    |> where(character_id: ^character_id)
    |> order_by(:slot)
    |> Repo.all()
  end
end
