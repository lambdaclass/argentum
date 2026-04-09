defmodule GameBackend.Guild do
  @moduledoc "Ecto schema for the `guilds` table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guilds" do
    field :name, :string
    field :leader_id, :integer
    field :description, :string, default: ""
    field :level, :integer, default: 1
    field :current_exp, :integer, default: 0
    field :news, :string, default: ""
    field :url, :string, default: ""
    field :alignment, :integer, default: 0
    has_many :members, GameBackend.GuildMember
    timestamps()
  end

  @cast_fields [:name, :leader_id, :description, :level, :current_exp, :news, :url, :alignment]

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
  def create_guild(char_id, name, alignment \\ 0) do
    Repo.transaction(fn ->
      case %Guild{} |> Guild.changeset(%{name: name, leader_id: char_id, alignment: alignment}) |> Repo.insert() do
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

  @doc "Update guild fields (level, exp, news, etc.)."
  def update_guild(guild_id, attrs) do
    case Repo.get(Guild, guild_id) do
      nil -> {:error, :not_found}
      guild -> guild |> Guild.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Find the guild a character belongs to."
  def get_guild_by_char(char_id) do
    case Repo.one(from m in GuildMember, where: m.char_id == ^char_id, select: m.guild_id) do
      nil -> nil
      guild_id -> Repo.get(Guild, guild_id) |> Repo.preload(:members)
    end
  end

  # ---- Guild Relations ----

  @doc "Load all guild relations."
  def list_relations do
    Repo.all(GameBackend.GuildRelation)
  end

  @doc "Set relation between two guilds. Always stores with min(a,b) as guild_a_id."
  def set_relation(guild_a_id, guild_b_id, relation_type) do
    {a, b} = if guild_a_id <= guild_b_id, do: {guild_a_id, guild_b_id}, else: {guild_b_id, guild_a_id}

    case Repo.one(
           from r in GameBackend.GuildRelation,
             where: r.guild_a_id == ^a and r.guild_b_id == ^b
         ) do
      nil ->
        %GameBackend.GuildRelation{}
        |> GameBackend.GuildRelation.changeset(%{
          guild_a_id: a,
          guild_b_id: b,
          relation_type: relation_type
        })
        |> Repo.insert()

      relation ->
        relation
        |> GameBackend.GuildRelation.changeset(%{relation_type: relation_type})
        |> Repo.update()
    end
  end

  @doc "Delete a relation between two guilds."
  def delete_relation(guild_a_id, guild_b_id) do
    {a, b} = if guild_a_id <= guild_b_id, do: {guild_a_id, guild_b_id}, else: {guild_b_id, guild_a_id}

    from(r in GameBackend.GuildRelation,
      where: r.guild_a_id == ^a and r.guild_b_id == ^b
    )
    |> Repo.delete_all()
  end

  # ---- Guild Requests (Aspirant System) ----

  @doc "Create a membership request."
  def create_request(guild_id, char_id, description \\ "") do
    %GameBackend.GuildRequest{}
    |> GameBackend.GuildRequest.changeset(%{guild_id: guild_id, char_id: char_id, description: description})
    |> Repo.insert()
  end

  @doc "List pending requests for a guild."
  def list_requests(guild_id) do
    from(r in GameBackend.GuildRequest, where: r.guild_id == ^guild_id)
    |> Repo.all()
  end

  @doc "Delete a request (on accept or reject)."
  def delete_request(guild_id, char_id) do
    from(r in GameBackend.GuildRequest,
      where: r.guild_id == ^guild_id and r.char_id == ^char_id
    )
    |> Repo.delete_all()
  end
end

defmodule GameBackend.GuildRelation do
  @moduledoc "Ecto schema for guild_relations table (war/peace/alliance)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guild_relations" do
    field :guild_a_id, :integer
    field :guild_b_id, :integer
    field :relation_type, :string, default: "peace"
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

defmodule GameBackend.GuildRequest do
  @moduledoc "Ecto schema for guild_requests table (membership petitions)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "guild_requests" do
    field :guild_id, :integer
    field :char_id, :integer
    field :description, :string, default: ""
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
