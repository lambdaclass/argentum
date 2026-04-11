defmodule GameBackend.GuildMember do
  @moduledoc "Ecto schema for the `guild_members` table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guild_members" do
    belongs_to(:guild, GameBackend.Guild)
    field(:char_id, :integer)
    field(:rank, :string, default: "member")
    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:guild_id, :char_id, :rank])
    |> validate_required([:guild_id, :char_id])
    |> validate_inclusion(:rank, ["leader", "officer", "member"])
    |> unique_constraint([:guild_id, :char_id])
    |> unique_constraint(:char_id)
  end
end
