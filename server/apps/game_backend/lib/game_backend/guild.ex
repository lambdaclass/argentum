defmodule GameBackend.Guild do
  @moduledoc "Ecto schema for the `guilds` table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guilds" do
    field(:name, :string)
    field(:leader_id, :integer)
    field(:founder_id, :integer)
    field(:description, :string, default: "")
    field(:level, :integer, default: 1)
    field(:current_exp, :integer, default: 0)
    field(:news, :string, default: "")
    field(:url, :string, default: "")
    field(:alignment, :integer, default: 0)
    has_many(:members, GameBackend.GuildMember)
    timestamps()
  end

  @cast_fields [:name, :leader_id, :founder_id, :description, :level, :current_exp, :news, :url, :alignment]

  def changeset(guild, attrs) do
    guild
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :leader_id])
    |> validate_length(:name, min: 3, max: 30)
    |> validate_inclusion(:level, 1..7)
    |> validate_inclusion(:alignment, 0..4)
    |> unique_constraint(:name)
  end
end
