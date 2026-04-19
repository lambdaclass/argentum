defmodule Arena.Adversarial.SpellAuthorityTest do
  @moduledoc """
  Adversarial tests for spell authority and stale-state behavior.

  These focus on the trust boundary for spell casting:
  - casting must use the server-side in-memory spellbook, not the DB per cast
  - invalid or stale spell slots must not mutate resources or cooldowns
  - spell reordering must not allow cooldown bypass
  """

  use ExUnit.Case, async: false

  alias AoEntities.PlayerEntity
  alias Arena.Data.{GameData, SpellDef}
  alias Arena.Map.{CombatHandlers, Social}
  alias GameBackend.{Account, Characters}

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)
    :ok
  end

  defp make_entity(overrides \\ %{}) do
    struct!(PlayerEntity, Map.merge(%{
      char_id: :caster,
      name: "Caster",
      account_id: 1,
      x: 50,
      y: 50,
      char_index: 1,
      map_id: 1,
      hp: 90,
      max_hp: 100,
      mana: 200,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      skills: %{magic: 80},
      spells: [],
      spell_cooldowns: %{}
    }, overrides))
  end

  defp make_state(players, opts \\ []) do
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, safe_zone: false, sin_invi_ocul: false}
    )
  end

  defp put_spell(spell_id, overrides \\ %{}) do
    spell =
      struct!(SpellDef, Map.merge(%{
        id: spell_id,
        name: "Test Spell #{spell_id}",
        mana_required: 10,
        sta_required: 0,
        min_skill: 0,
        cooldown: 2,
        sube_hp: 1,
        min_hp: 5,
        max_hp: 5
      }, overrides))

    :ets.insert(:arena_game_data, {{:spell, spell_id}, spell})
    on_exit(fn -> :ets.delete(:arena_game_data, {:spell, spell_id}) end)
    spell
  end

  defp create_character_with_spells(name, spell_ids) do
    {:ok, account} = Account.get_or_create(name, "testpass")

    {:ok, character} =
      Characters.create(
        %{name: name, account_id: account.id, map_id: 1, pos_x: 50, pos_y: 50},
        spells: spell_ids
      )

    character
  end

  defp save_spellbook(entity, spell_ids) do
    Characters.save_snapshot(
      entity.char_id,
      Characters.from_entity(entity),
      inventory: Characters.inventory_from_entity(entity),
      equipment: Characters.equipment_from_entity(entity),
      skills: Characters.skills_from_entity(entity),
      spells: spell_ids
    )
  end

  describe "invalid or stale spell slots" do
    test "slot with spell_id 0 is rejected without mutating resources or cooldowns" do
      state = make_state(%{caster: make_entity(%{spells: [0]})})

      {:reply, {:error, :unknown_spell}, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      updated = new_state.players.caster
      assert updated.mana == 200
      assert updated.stamina == 100
      assert updated.spell_cooldowns == %{}
    end

    test "unknown spell definition in a known slot is rejected without side effects" do
      state = make_state(%{caster: make_entity(%{spells: [98_765]})})

      {:reply, {:error, :unknown_spell}, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      updated = new_state.players.caster
      assert updated.mana == 200
      assert updated.stamina == 100
      assert updated.spell_cooldowns == %{}
    end
  end

  describe "spell-slot reordering" do
    test "moving a spell swaps cooldown ownership so reordering cannot bypass cooldown" do
      put_spell(98_761)
      put_spell(98_762)

      far_future = System.monotonic_time(:millisecond) + 60_000

      entity =
        make_entity(%{
          spells: [98_761, 98_762],
          spell_cooldowns: %{1 => far_future}
        })

      state = make_state(%{caster: entity})

      {:noreply, moved_state} = Social.handle_move_spell(state, :caster, false, 1)

      moved = moved_state.players.caster
      assert moved.spells == [98_762, 98_761]
      assert moved.spell_cooldowns[2] == far_future
      refute Map.has_key?(moved.spell_cooldowns, 1)

      {:reply, :ok, _} = CombatHandlers.handle_cast_spell(moved_state, :caster, 1, nil, nil)
      {:reply, {:error, :cooldown}, _} = CombatHandlers.handle_cast_spell(moved_state, :caster, 2, nil, nil)
    end
  end

  describe "online spell authority is in memory, not per-cast DB" do
    test "DB spell removal does not revoke cast rights until the player reloads" do
      spell_id = 98_763
      put_spell(spell_id)

      name = "SpellOnlineRemove_#{System.unique_integer([:positive])}"
      character = create_character_with_spells(name, [spell_id])
      entity = Characters.to_entity(character)

      state = make_state(%{character.id => entity})

      assert {:ok, _} = save_spellbook(entity, [])

      {:reply, :ok, _} = CombatHandlers.handle_cast_spell(state, character.id, 1, nil, nil)

      reloaded = character.id |> Characters.get() |> Characters.to_entity()
      assert reloaded.spells == []

      reloaded_state = make_state(%{character.id => reloaded})
      {:reply, {:error, :invalid_slot}, _} = CombatHandlers.handle_cast_spell(reloaded_state, character.id, 1, nil, nil)
    end

    test "DB spell grant does not grant cast rights until the player reloads" do
      spell_id = 98_764
      put_spell(spell_id)

      name = "SpellOnlineGrant_#{System.unique_integer([:positive])}"
      character = create_character_with_spells(name, [])
      entity = Characters.to_entity(character)

      state = make_state(%{character.id => entity})

      assert {:ok, _} = save_spellbook(entity, [spell_id])

      {:reply, {:error, :invalid_slot}, _} = CombatHandlers.handle_cast_spell(state, character.id, 1, nil, nil)

      reloaded = character.id |> Characters.get() |> Characters.to_entity()
      assert reloaded.spells == [spell_id]

      reloaded_state = make_state(%{character.id => reloaded})
      {:reply, :ok, _} = CombatHandlers.handle_cast_spell(reloaded_state, character.id, 1, nil, nil)
    end
  end
end
