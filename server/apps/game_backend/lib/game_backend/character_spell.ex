defmodule GameBackend.CharacterSpell do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "character_spells" do
    belongs_to :character, GameBackend.Characters
    field :spell_id, :integer
    timestamps()
  end

  def changeset(spell, attrs) do
    spell
    |> cast(attrs, [:character_id, :spell_id])
    |> validate_required([:character_id, :spell_id])
    |> unique_constraint([:character_id, :spell_id])
  end
end
