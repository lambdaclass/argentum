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
    field(:character_id, :integer)
    field(:slot, :integer)
    field(:item_id, :integer)
    field(:amount, :integer, default: 1)
    field(:elemental_tags, :integer, default: 0)

    timestamps()
  end

  def changeset(bank_item, attrs) do
    bank_item
    |> cast(attrs, [:character_id, :slot, :item_id, :amount, :elemental_tags])
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

  @default_max_stack 10_000

  @doc "Upsert a bank item: add to existing slot or insert new. Caps at max_stack."
  def upsert(character_id, slot, item_id, amount, elemental_tags \\ 0, max_stack \\ @default_max_stack) do
    existing =
      __MODULE__
      |> where(character_id: ^character_id, slot: ^slot)
      |> Repo.one()

    if existing do
      new_amount = min(existing.amount + amount, max_stack)

      existing
      |> change(%{amount: new_amount, item_id: item_id, elemental_tags: elemental_tags})
      |> Repo.update()
    else
      capped_amount = min(amount, max_stack)

      %__MODULE__{}
      |> changeset(%{
        character_id: character_id,
        slot: slot,
        item_id: item_id,
        amount: capped_amount,
        elemental_tags: elemental_tags
      })
      |> Repo.insert()
    end
  end

  @doc "Remove amount from a bank slot. Deletes the row if amount reaches 0."
  def withdraw(character_id, slot, amount) do
    existing =
      __MODULE__
      |> where(character_id: ^character_id, slot: ^slot)
      |> Repo.one()

    case existing do
      nil ->
        {:error, :not_found}

      bi when bi.amount <= amount ->
        Repo.delete(bi)
        {:ok, :deleted}

      bi ->
        bi |> change(%{amount: bi.amount - amount}) |> Repo.update()
    end
  end
end
