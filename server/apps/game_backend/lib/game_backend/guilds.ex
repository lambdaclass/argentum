defmodule GameBackend.Guild do
  @moduledoc "Ecto schema for the `guilds` table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guilds" do
    field :name, :string
    field :leader_id, :integer
    field :description, :string, default: ""
    has_many :members, GameBackend.GuildMember
    timestamps()
  end

  def changeset(guild, attrs) do
    guild
    |> cast(attrs, [:name, :leader_id, :description])
    |> validate_required([:name, :leader_id])
    |> validate_length(:name, min: 3, max: 30)
    |> unique_constraint(:name)
  end
end

defmodule GameBackend.GuildMember do
  @moduledoc "Ecto schema for the `guild_members` table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guild_members" do
    belongs_to :guild, GameBackend.Guild
    field :char_id, :integer
    field :rank, :string, default: "member"
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

defmodule GameBackend.Guilds do
  @moduledoc """
  Context module for guild persistence.

  Provides CRUD operations used by `Arena.GuildServer` for write-through
  persistence while ETS remains the fast-read path.
  """

  import Ecto.Query
  alias GameBackend.Repo
  alias GameBackend.Guild
  alias GameBackend.GuildMember

  @doc "Load all guilds with their members. Used by GuildServer init."
  def list_all do
    Guild
    |> preload(:members)
    |> Repo.all()
  end

  @doc "Create a guild and insert the creator as leader member."
  def create_guild(char_id, name) do
    Repo.transaction(fn ->
      case %Guild{} |> Guild.changeset(%{name: name, leader_id: char_id}) |> Repo.insert() do
        {:ok, guild} ->
          {:ok, member} =
            %GuildMember{}
            |> GuildMember.changeset(%{guild_id: guild.id, char_id: char_id, rank: "leader"})
            |> Repo.insert()

          %{guild | members: [member]}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Add a member to a guild."
  def add_member(guild_id, char_id) do
    %GuildMember{}
    |> GuildMember.changeset(%{guild_id: guild_id, char_id: char_id, rank: "member"})
    |> Repo.insert()
  end

  @doc "Remove a member from a guild."
  def remove_member(guild_id, char_id) do
    from(m in GuildMember, where: m.guild_id == ^guild_id and m.char_id == ^char_id)
    |> Repo.delete_all()
  end

  @doc "Delete a guild and all its members (cascade)."
  def delete_guild(guild_id) do
    Repo.transaction(fn ->
      from(m in GuildMember, where: m.guild_id == ^guild_id) |> Repo.delete_all()

      case Repo.get(Guild, guild_id) do
        nil -> :ok
        guild -> Repo.delete!(guild)
      end
    end)
  end

  @doc "Find the guild a character belongs to."
  def get_guild_by_char(char_id) do
    case Repo.one(from m in GuildMember, where: m.char_id == ^char_id, select: m.guild_id) do
      nil -> nil
      guild_id -> Repo.get(Guild, guild_id) |> Repo.preload(:members)
    end
  end
end
