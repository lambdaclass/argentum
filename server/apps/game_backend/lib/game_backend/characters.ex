defmodule GameBackend.Characters do
  @moduledoc """
  Ecto schema and queries for character persistence.

  The DB is authoritative only when the player is offline.
  While online, the MapServer entity is authoritative and
  periodically snapshots here.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias GameBackend.Repo
  alias GameBackend.InventorySlot
  alias GameBackend.CharacterEquipment

  @primary_key {:id, :id, autogenerate: true}
  schema "characters" do
    field :name, :string
    field :account_id, :string
    field :race, :string, default: "human"
    field :class, :string, default: "warrior"
    field :gender, :string, default: "male"
    field :home_city, :string, default: "ullathorpe"

    field :level, :integer, default: 1
    field :xp, :integer, default: 0
    field :skill_points, :integer, default: 0

    field :map_id, :integer, default: 1
    field :pos_x, :integer, default: 50
    field :pos_y, :integer, default: 50
    field :heading, :string, default: "south"

    field :hp, :integer, default: 100
    field :max_hp, :integer, default: 100
    field :mana, :integer, default: 100
    field :max_mana, :integer, default: 100
    field :stamina, :integer, default: 100
    field :max_stamina, :integer, default: 100
    field :hunger, :integer, default: 100
    field :thirst, :integer, default: 100

    field :str, :integer, default: 18
    field :agi, :integer, default: 18
    field :int, :integer, default: 18
    field :con, :integer, default: 18
    field :cha, :integer, default: 18

    field :gold, :integer, default: 0
    field :bank_gold, :integer, default: 0

    field :body_id, :integer, default: 1
    field :head_id, :integer, default: 1

    # Flags stored as booleans
    field :dead, :boolean, default: false
    field :criminal, :boolean, default: false
    field :gm, :boolean, default: false

    # Skills stored as JSON map: %{"mining" => 10, "combat" => 5}
    field :skills, :map, default: %{}

    # Spells stored as JSON list: [1, 5, 12]
    field :spells, {:array, :integer}, default: []

    field :session_token, :string

    has_many :inventory_slots, InventorySlot, foreign_key: :character_id
    has_one :equipment, CharacterEquipment, foreign_key: :character_id

    timestamps()
  end

  @required_fields [:name, :account_id]
  @optional_fields [
    :race, :class, :gender, :home_city,
    :level, :xp, :skill_points,
    :map_id, :pos_x, :pos_y, :heading,
    :hp, :max_hp, :mana, :max_mana, :stamina, :max_stamina,
    :hunger, :thirst,
    :str, :agi, :int, :con, :cha,
    :gold, :bank_gold, :body_id, :head_id,
    :dead, :criminal, :gm,
    :skills, :spells, :session_token
  ]

  def changeset(character, attrs) do
    character
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 3, max: 30)
    |> unique_constraint(:name)
  end

  @doc "Create a new character with inventory and equipment."
  def create(attrs, opts \\ []) do
    inventory = Keyword.get(opts, :inventory, [])
    equipment = Keyword.get(opts, :equipment, %{})

    # Generate a session token for the new character
    attrs = Map.put_new(attrs, :session_token, generate_token())

    Repo.transaction(fn ->
      case %__MODULE__{} |> changeset(attrs) |> Repo.insert() do
        {:ok, character} ->
          save_inventory_slots(character.id, inventory)
          save_equipment(character.id, equipment)

          character
          |> Repo.preload([:inventory_slots, :equipment])

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Load a character by ID."
  def get(id) do
    __MODULE__
    |> Repo.get(id)
    |> preload_associations()
  end

  @doc "Load a character by name."
  def get_by_name(name) do
    __MODULE__
    |> Repo.get_by(name: name)
    |> preload_associations()
  end

  defp preload_associations(nil), do: nil
  defp preload_associations(character), do: Repo.preload(character, [:inventory_slots, :equipment])

  @doc "Save a snapshot of online player state back to DB."
  def save_snapshot(char_id, attrs, opts \\ []) do
    inventory = Keyword.get(opts, :inventory, [])
    equipment = Keyword.get(opts, :equipment, %{})

    Repo.transaction(fn ->
      case get(char_id) do
        nil ->
          Repo.rollback(:not_found)

        character ->
          case character |> changeset(attrs) |> Repo.update() do
            {:ok, character} ->
              save_inventory_slots(character.id, inventory)
              save_equipment(character.id, equipment)
              character |> Repo.preload([:inventory_slots, :equipment], force: true)

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc "Convert a DB record to a PlayerEntity struct."
  def to_entity(%__MODULE__{} = c) do
    %Arena.Entity.PlayerEntity{
      char_id: c.id,
      name: c.name,
      account_id: c.account_id,
      x: c.pos_x,
      y: c.pos_y,
      heading: String.to_atom(c.heading),
      body_id: c.body_id,
      head_id: c.head_id,
      hp: c.hp,
      max_hp: c.max_hp,
      mana: c.mana,
      max_mana: c.max_mana,
      stamina: c.stamina,
      max_stamina: c.max_stamina,
      hunger: c.hunger,
      thirst: c.thirst,
      level: c.level,
      xp: c.xp,
      skill_points: c.skill_points,
      class: String.to_atom(c.class),
      race: String.to_atom(c.race),
      gender: String.to_atom(c.gender),
      home_city: String.to_atom(c.home_city),
      str: c.str,
      agi: c.agi,
      int: c.int,
      con: c.con,
      cha: c.cha,
      gold: c.gold,
      inventory: slots_to_inventory(c.inventory_slots),
      equipment: row_to_equipment(c.equipment),
      skills: c.skills,
      spells: c.spells,
      dead: c.dead,
      criminal: c.criminal,
      gm: c.gm,
      map_id: c.map_id
    }
  end

  @doc "Convert a PlayerEntity back to DB-saveable attrs (character fields only)."
  def from_entity(%Arena.Entity.PlayerEntity{} = e) do
    %{
      name: e.name,
      account_id: e.account_id,
      race: to_string(e.race),
      class: to_string(e.class),
      gender: to_string(e.gender),
      home_city: to_string(e.home_city),
      pos_x: e.x,
      pos_y: e.y,
      heading: to_string(e.heading),
      body_id: e.body_id,
      head_id: e.head_id,
      hp: e.hp,
      max_hp: e.max_hp,
      mana: e.mana,
      max_mana: e.max_mana,
      stamina: e.stamina,
      max_stamina: e.max_stamina,
      hunger: e.hunger,
      thirst: e.thirst,
      level: e.level,
      xp: e.xp,
      skill_points: e.skill_points,
      str: e.str,
      agi: e.agi,
      int: e.int,
      con: e.con,
      cha: e.cha,
      gold: e.gold,
      skills: e.skills,
      spells: e.spells,
      dead: e.dead,
      criminal: e.criminal,
      map_id: e.map_id
    }
  end

  @doc "Extract inventory list from entity for saving."
  def inventory_from_entity(%Arena.Entity.PlayerEntity{} = e), do: e.inventory

  @doc "Extract equipment map from entity for saving."
  def equipment_from_entity(%Arena.Entity.PlayerEntity{} = e), do: e.equipment

  @doc "Validate a session token for a character. Returns true if valid."
  def valid_token?(%__MODULE__{session_token: stored}, token)
      when is_binary(stored) and is_binary(token) and byte_size(stored) > 0 do
    Plug.Crypto.secure_compare(stored, token)
  end

  def valid_token?(_, _), do: false

  @doc "Generate a new random session token."
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # ---- Private helpers ----

  defp save_inventory_slots(character_id, inventory) do
    # Delete existing slots
    from(s in InventorySlot, where: s.character_id == ^character_id) |> Repo.delete_all()

    # Insert non-nil slots
    inventory
    |> Enum.with_index()
    |> Enum.each(fn
      {nil, _idx} -> :ok
      {%{item_id: item_id, amount: amount, equipped: equipped}, idx} ->
        %InventorySlot{}
        |> InventorySlot.changeset(%{
          character_id: character_id,
          slot: idx,
          item_id: item_id,
          amount: amount,
          equipped: equipped
        })
        |> Repo.insert!()
    end)
  end

  defp save_equipment(character_id, equipment) when equipment == %{} or equipment == nil, do:
    save_equipment(character_id, %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil})

  defp save_equipment(character_id, equipment) do
    case Repo.get_by(CharacterEquipment, character_id: character_id) do
      nil ->
        %CharacterEquipment{}
        |> CharacterEquipment.changeset(%{
          character_id: character_id,
          weapon: equipment[:weapon] || equipment["weapon"],
          armor: equipment[:armor] || equipment["armor"],
          shield: equipment[:shield] || equipment["shield"],
          helmet: equipment[:helmet] || equipment["helmet"],
          ring: equipment[:ring] || equipment["ring"]
        })
        |> Repo.insert!()

      existing ->
        existing
        |> CharacterEquipment.changeset(%{
          weapon: equipment[:weapon] || equipment["weapon"],
          armor: equipment[:armor] || equipment["armor"],
          shield: equipment[:shield] || equipment["shield"],
          helmet: equipment[:helmet] || equipment["helmet"],
          ring: equipment[:ring] || equipment["ring"]
        })
        |> Repo.update!()
    end
  end

  defp slots_to_inventory(nil), do: List.duplicate(nil, 24)
  defp slots_to_inventory(%Ecto.Association.NotLoaded{}), do: List.duplicate(nil, 24)

  defp slots_to_inventory(slots) do
    base = List.duplicate(nil, 24)

    Enum.reduce(slots, base, fn slot, acc ->
      item = %{item_id: slot.item_id, amount: slot.amount, equipped: slot.equipped}
      List.replace_at(acc, slot.slot, item)
    end)
  end

  defp row_to_equipment(nil), do: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
  defp row_to_equipment(%Ecto.Association.NotLoaded{}), do: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}

  defp row_to_equipment(%CharacterEquipment{} = eq) do
    %{weapon: eq.weapon, armor: eq.armor, shield: eq.shield, helmet: eq.helmet, ring: eq.ring}
  end
end
