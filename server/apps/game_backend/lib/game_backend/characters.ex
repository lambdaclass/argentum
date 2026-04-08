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
  alias GameBackend.CharacterSkill
  alias GameBackend.CharacterSpell
  alias GameBackend.BankItems

  @primary_key {:id, :id, autogenerate: true}
  schema "characters" do
    field :name, :string
    belongs_to :account, GameBackend.Account
    field :race, :string, default: "human"
    field :class, :string, default: "warrior"
    field :gender, :string, default: "male"
    field :home_city, :string, default: "ullathorpe"
    field :faction, :string, default: "none"

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

    # Faction kill counters
    field :faction_kills_royal, :integer, default: 0
    field :faction_kills_chaos, :integer, default: 0
    field :citizens_killed, :integer, default: 0
    field :criminals_killed, :integer, default: 0

    # Faction progression
    field :faction_score, :integer, default: 0
    field :faction_rank_armada, :integer, default: 0
    field :faction_rank_chaos, :integer, default: 0
    field :faction_reenlistadas, :integer, default: 0

    # Lifetime counters (mini_stats)
    field :npcs_killed, :integer, default: 0
    field :deaths, :integer, default: 0
    field :penalty, :integer, default: 0
    field :fishing_points, :integer, default: 0

    # Flags stored as booleans
    field :dead, :boolean, default: false
    field :criminal, :boolean, default: false
    field :gm, :boolean, default: false

    field :muted_until, :integer, default: 0

    field :session_token, :string

    has_many :inventory_slots, InventorySlot, foreign_key: :character_id
    has_one :equipment, CharacterEquipment, foreign_key: :character_id
    has_many :character_skills, CharacterSkill, foreign_key: :character_id
    has_many :character_spells, CharacterSpell, foreign_key: :character_id
    has_many :bank_items, BankItems, foreign_key: :character_id

    timestamps()
  end

  @required_fields [:name, :account_id]
  @optional_fields [
    :race, :class, :gender, :home_city, :faction,
    :level, :xp, :skill_points,
    :map_id, :pos_x, :pos_y, :heading,
    :hp, :max_hp, :mana, :max_mana, :stamina, :max_stamina,
    :hunger, :thirst,
    :str, :agi, :int, :con, :cha,
    :gold, :bank_gold, :body_id, :head_id,
    :faction_kills_royal, :faction_kills_chaos, :citizens_killed, :criminals_killed,
    :faction_score, :faction_rank_armada, :faction_rank_chaos, :faction_reenlistadas,
    :npcs_killed, :deaths, :penalty, :fishing_points,
    :dead, :criminal, :gm,
    :muted_until,
    :session_token
  ]

  def changeset(character, attrs) do
    character
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 3, max: 30)
    |> unique_constraint(:name)
  end

  @preload_associations [:inventory_slots, :equipment, :character_skills, :character_spells, :bank_items]

  @doc "Create a new character with inventory, equipment, skills, and spells."
  def create(attrs, opts \\ []) do
    inventory = Keyword.get(opts, :inventory, [])
    equipment = Keyword.get(opts, :equipment, %{})
    skills = Keyword.get(opts, :skills, %{})
    spells = Keyword.get(opts, :spells, [])

    # Generate a session token for the new character
    attrs = Map.put_new(attrs, :session_token, generate_token())

    Repo.transaction(fn ->
      case %__MODULE__{} |> changeset(attrs) |> Repo.insert() do
        {:ok, character} ->
          save_inventory_slots(character.id, inventory)
          save_equipment(character.id, equipment)
          save_skills(character.id, skills)
          save_spells(character.id, spells)

          character
          |> Repo.preload(@preload_associations)

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
  defp preload_associations(character), do: Repo.preload(character, @preload_associations)

  @doc "Save a snapshot of online player state back to DB."
  def save_snapshot(char_id, attrs, opts \\ []) do
    inventory = Keyword.get(opts, :inventory, [])
    equipment = Keyword.get(opts, :equipment, %{})
    skills = Keyword.get(opts, :skills, %{})
    spells = Keyword.get(opts, :spells, [])
    bank_items = Keyword.get(opts, :bank_items)

    Repo.transaction(fn ->
      case get(char_id) do
        nil ->
          Repo.rollback(:not_found)

        character ->
          case character |> changeset(attrs) |> Repo.update() do
            {:ok, character} ->
              save_inventory_slots(character.id, inventory)
              save_equipment(character.id, equipment)
              save_skills(character.id, skills)
              save_spells(character.id, spells)
              if bank_items, do: save_bank_items(character.id, bank_items)
              character |> Repo.preload(@preload_associations, force: true)

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  # Naked body IDs by {race_string, gender_string} — mirrors @body_ids in CharacterCreation
  @naked_body_ids %{
    {"humano", "male"} => 1,   {"humano", "female"} => 1,
    {"elfo", "male"} => 2,     {"elfo", "female"} => 2,
    {"elfo_oscuro", "male"} => 3, {"elfo_oscuro", "female"} => 3,
    {"enano", "male"} => 300,  {"enano", "female"} => 300,
    {"gnomo", "male"} => 300,  {"gnomo", "female"} => 300,
    {"orco", "male"} => 582,   {"orco", "female"} => 581
  }

  @doc "Convert a DB record to a PlayerEntity struct."
  def to_entity(%__MODULE__{} = c) do
    base_body = Map.get(@naked_body_ids, {c.race, c.gender}, c.body_id)

    %Arena.Entity.PlayerEntity{
      char_id: c.id,
      name: c.name,
      account_id: c.account_id,
      x: c.pos_x,
      y: c.pos_y,
      heading: String.to_atom(c.heading),
      body_id: c.body_id,
      base_body_id: base_body,
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
      faction: String.to_atom(c.faction),
      str: c.str,
      agi: c.agi,
      int: c.int,
      con: c.con,
      cha: c.cha,
      gold: c.gold,
      inventory: slots_to_inventory(c.inventory_slots),
      equipment: row_to_equipment(c.equipment),
      skills: rows_to_skills(c.character_skills),
      spells: rows_to_spells(c.character_spells),
      faction_kills_royal: c.faction_kills_royal,
      faction_kills_chaos: c.faction_kills_chaos,
      citizens_killed: c.citizens_killed,
      criminals_killed: c.criminals_killed,
      faction_score: c.faction_score,
      faction_rank_armada: c.faction_rank_armada,
      faction_rank_chaos: c.faction_rank_chaos,
      faction_reenlistadas: c.faction_reenlistadas,
      npcs_killed: c.npcs_killed,
      deaths: c.deaths,
      penalty: c.penalty,
      fishing_points: c.fishing_points,
      dead: c.dead,
      criminal: c.criminal,
      gm: c.gm,
      muted_until: c.muted_until || 0,
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
      faction: to_string(e.faction),
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
      faction_kills_royal: e.faction_kills_royal,
      faction_kills_chaos: e.faction_kills_chaos,
      citizens_killed: e.citizens_killed,
      criminals_killed: e.criminals_killed,
      faction_score: e.faction_score,
      faction_rank_armada: e.faction_rank_armada,
      faction_rank_chaos: e.faction_rank_chaos,
      faction_reenlistadas: e.faction_reenlistadas,
      npcs_killed: e.npcs_killed,
      deaths: e.deaths,
      penalty: e.penalty,
      fishing_points: e.fishing_points,
      dead: e.dead,
      criminal: e.criminal,
      muted_until: e.muted_until,
      map_id: e.map_id
    }
  end

  @doc "Extract inventory list from entity for saving."
  def inventory_from_entity(%Arena.Entity.PlayerEntity{} = e), do: e.inventory

  @doc "Extract equipment map from entity for saving."
  def equipment_from_entity(%Arena.Entity.PlayerEntity{} = e), do: e.equipment

  @doc "Extract skills map from entity for saving."
  def skills_from_entity(%Arena.Entity.PlayerEntity{} = e), do: e.skills

  @doc "Extract spells list from entity for saving."
  def spells_from_entity(%Arena.Entity.PlayerEntity{} = e), do: e.spells

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
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Collect occupied and empty slot indices
    {occupied, empty} =
      inventory
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn
        {nil, idx}, {occ, emp} -> {occ, [idx | emp]}
        {_item, idx}, {occ, emp} -> {[idx | occ], emp}
      end)

    # Delete slots that are now empty (were occupied before)
    if empty != [] do
      from(s in InventorySlot,
        where: s.character_id == ^character_id and s.slot in ^empty
      )
      |> Repo.delete_all()
    end

    # Upsert occupied slots
    Enum.each(occupied, fn idx ->
      %{item_id: item_id, amount: amount, equipped: equipped} = Enum.at(inventory, idx)

      Repo.insert!(
        %InventorySlot{
          character_id: character_id,
          slot: idx,
          item_id: item_id,
          amount: amount,
          equipped: equipped,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [item_id: item_id, amount: amount, equipped: equipped, updated_at: now]],
        conflict_target: [:character_id, :slot]
      )
    end)
  end

  defp save_equipment(character_id, equipment) when equipment == %{} or equipment == nil, do:
    save_equipment(character_id, %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil})

  defp save_equipment(character_id, equipment) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    weapon = equipment[:weapon] || equipment["weapon"]
    armor = equipment[:armor] || equipment["armor"]
    shield = equipment[:shield] || equipment["shield"]
    helmet = equipment[:helmet] || equipment["helmet"]
    ring = equipment[:ring] || equipment["ring"]
    municion = equipment[:municion] || equipment["municion"]

    Repo.insert!(
      %CharacterEquipment{
        character_id: character_id,
        weapon: weapon,
        armor: armor,
        shield: shield,
        helmet: helmet,
        ring: ring,
        municion: municion,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [weapon: weapon, armor: armor, shield: shield, helmet: helmet, ring: ring, municion: municion, updated_at: now]],
      conflict_target: [:character_id]
    )
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

  defp row_to_equipment(nil), do: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}
  defp row_to_equipment(%Ecto.Association.NotLoaded{}), do: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}

  defp row_to_equipment(%CharacterEquipment{} = eq) do
    %{weapon: eq.weapon, armor: eq.armor, shield: eq.shield, helmet: eq.helmet, ring: eq.ring, municion: eq.municion}
  end

  # ---- Skills ----

  defp save_skills(_character_id, skills) when skills == %{} or skills == nil, do: :ok

  defp save_skills(character_id, skills) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    current_names = Map.keys(skills)

    # Delete skills no longer present
    from(s in CharacterSkill,
      where: s.character_id == ^character_id and s.skill_name not in ^current_names
    )
    |> Repo.delete_all()

    # Upsert current skills
    Enum.each(skills, fn {skill_name, level} ->
      Repo.insert!(
        %CharacterSkill{
          character_id: character_id,
          skill_name: to_string(skill_name),
          level: level,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [level: level, updated_at: now]],
        conflict_target: [:character_id, :skill_name]
      )
    end)
  end

  defp rows_to_skills(nil), do: %{}
  defp rows_to_skills(%Ecto.Association.NotLoaded{}), do: %{}

  defp rows_to_skills(rows) do
    Map.new(rows, fn row -> {String.to_atom(row.skill_name), row.level} end)
  end

  # ---- Spells ----

  defp save_spells(_character_id, spells) when spells == [] or spells == nil, do: :ok

  defp save_spells(character_id, spells) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Delete spells no longer known
    from(s in CharacterSpell,
      where: s.character_id == ^character_id and s.spell_id not in ^spells
    )
    |> Repo.delete_all()

    # Upsert current spells
    Enum.each(spells, fn spell_id ->
      Repo.insert!(
        %CharacterSpell{
          character_id: character_id,
          spell_id: spell_id,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: :nothing,
        conflict_target: [:character_id, :spell_id]
      )
    end)
  end

  defp rows_to_spells(nil), do: []
  defp rows_to_spells(%Ecto.Association.NotLoaded{}), do: []

  defp rows_to_spells(rows) do
    Enum.map(rows, & &1.spell_id)
  end

  # ---- Bank items ----

  defp save_bank_items(_character_id, items) when items == [] or items == nil, do: :ok

  defp save_bank_items(character_id, items) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    slot_indices = Enum.map(items, & &1.slot)

    from(b in BankItems,
      where: b.character_id == ^character_id and b.slot not in ^slot_indices
    )
    |> Repo.delete_all()

    Enum.each(items, fn %{slot: slot, item_id: item_id, amount: amount} ->
      Repo.insert!(
        %BankItems{
          character_id: character_id,
          slot: slot,
          item_id: item_id,
          amount: amount,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [item_id: item_id, amount: amount, updated_at: now]],
        conflict_target: [:character_id, :slot]
      )
    end)
  end

  @doc "Extract bank items list from a preloaded character record."
  def bank_items_from_db(%__MODULE__{bank_items: %Ecto.Association.NotLoaded{}}), do: []
  def bank_items_from_db(%__MODULE__{bank_items: nil}), do: []

  def bank_items_from_db(%__MODULE__{bank_items: items}) do
    Enum.map(items, fn b -> %{slot: b.slot, item_id: b.item_id, amount: b.amount} end)
  end
end
