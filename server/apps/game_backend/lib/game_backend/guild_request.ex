defmodule GameBackend.GuildRequest do
  @moduledoc "Ecto schema for guild_requests table (membership petitions)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guild_requests" do
    field(:guild_id, :integer)
    field(:char_id, :integer)
    field(:description, :string, default: "")
    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:guild_id, :char_id, :description])
    |> validate_required([:guild_id, :char_id])
    |> validate_length(:description, max: 256)
    |> unique_constraint([:guild_id, :char_id])
  end
end
