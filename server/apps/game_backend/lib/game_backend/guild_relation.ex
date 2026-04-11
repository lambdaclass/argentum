defmodule GameBackend.GuildRelation do
  @moduledoc "Ecto schema for guild_relations table (war/peace/alliance)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guild_relations" do
    field(:guild_a_id, :integer)
    field(:guild_b_id, :integer)
    field(:relation_type, :string, default: "peace")
    timestamps()
  end

  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:guild_a_id, :guild_b_id, :relation_type])
    |> validate_required([:guild_a_id, :guild_b_id, :relation_type])
    |> validate_inclusion(:relation_type, ["war", "peace", "alliance"])
    |> unique_constraint([:guild_a_id, :guild_b_id])
  end
end
