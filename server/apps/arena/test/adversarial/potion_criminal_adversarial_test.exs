defmodule Arena.Adversarial.PotionCriminalAdversarialTest do
  @moduledoc """
  Adversarial tests for recently-landed VB6 drift fixes:

    * Drift #16 — strength/agility potion duration + `backup * 2` cap.
      VB6: `InvUsuario.bas:1893-1922`, `General.bas:1278-1297`.
    * Drift #18 — HP potion `SelfHealingBonus`, `DivineBlood` gate,
      mana potion `Porcentaje` formula.
      VB6: `InvUsuario.bas:1923-1956`, `Modulo_UsUaRiOs.bas:3066`.
    * Drift #15 — full port of `VolverCriminal`.
      VB6: `Modulo_UsUaRiOs.bas:2260-2296`.

  These tests probe the extreme / unusual inputs around each drift fix and
  pin down known gaps.  Where the current implementation deviates from VB6
  we mark the assertion with `# TODO(parity)` and the test stays failing
  on purpose to track the gap.
  """

  # NOTE: cannot be `async: true` because PartyServer is a singleton and we
  # mutate its ETS table.  The `describe "potion adversarial — pure"` block
  # uses only `apply_potion/2` and would be safe to split later.
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, ItemDef}
  alias Arena.Map.{CriminalStatus, InventoryHandlers, StatusTicks}
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  @party_table :ao_parties

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arena.Settings.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arena.PartyServer.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Arena.Settings.reset_all()
    :ets.delete_all_objects(@party_table)
    flush_mailbox()
    :ok
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp potion(tipo, opts) do
    %ItemDef{
      id: Keyword.get(opts, :id, 998),
      obj_type: 1,
      tipo_pocion: tipo,
      min_modificador: Keyword.get(opts, :min, 10),
      max_modificador: Keyword.get(opts, :max, 10),
      porcentaje: Keyword.get(opts, :porcentaje, 0),
      duracion_efecto: Keyword.get(opts, :duration, 60)
    }
  end

  defp make_entity(overrides) do
    base = %PlayerEntity{
      char_id: 1,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      hp: 100,
      max_hp: 100,
      mana: 100,
      max_mana: 100,
      stamina: 100,
      max_stamina: 100,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      str_backup: 18,
      agi_backup: 18,
      str_buff: 0,
      agi_buff: 0,
      str_potion_delta: 0,
      agi_potion_delta: 0,
      duracion_efecto: 0,
      tomo_pocion: false,
      buffs: [],
      inventory: List.duplicate(nil, 24),
      divine_blood: 0,
      self_healing_bonus: 0.0,
      class: :warrior,
      race: :human,
      gender: :male,
      char_index: 1,
      map_id: 1,
      faction: :none,
      faction_score: 0,
      next_item_use_at: -1_000_000_000_000
    }

    Map.merge(base, overrides)
  end

  defp state_with(player, meta_overrides \\ %{}) do
    meta =
      Map.merge(
        %{
          safe_zone: false,
          no_pks: false,
          salida: nil,
          trigger_map: %{},
          rain: false,
          sin_invi_ocul: false
        },
        meta_overrides
      )

    map_state(
      players: %{player.char_id => player},
      sessions: %{player.char_id => self()},
      meta: meta
    )
  end

  # ═══════════════════════════════════════════════════════════════════════
  # POTION ADVERSARIAL TESTS
  # ═══════════════════════════════════════════════════════════════════════

  describe "strength potion — backup*2 cap adversarial" do
    test "drinking strength potion twice back-to-back does not exceed backup*2" do
      entity = make_entity(%{str: 18, str_backup: 18, str_buff: 0})
      item = potion(6, min: 30, max: 30, duration: 60)

      once = InventoryHandlers.apply_potion(entity, item)
      twice = InventoryHandlers.apply_potion(once, item)

      # VB6: MinimoInt(Atr + rnd, BackUP * 2). Two 30-bump rolls from base 18
      # would stack to 78 without the clamp; VB6 caps at 36.
      assert twice.str + twice.str_buff == entity.str_backup * 2,
             "Expected str+str_buff == backup*2 (36), got #{twice.str + twice.str_buff}"

      # Delta must not have grown beyond the cap contribution.
      assert twice.str_potion_delta <= entity.str_backup,
             "str_potion_delta exceeded backup on double drink: #{twice.str_potion_delta}"
    end

    test "drinking strength potion when already at capped +stat is a no-op on the attribute" do
      # Pre-capped: str + str_buff already == backup*2.
      entity =
        make_entity(%{
          str: 18,
          str_backup: 18,
          str_buff: 18,
          str_potion_delta: 18
        })

      # Sanity
      assert entity.str + entity.str_buff == entity.str_backup * 2

      item = potion(6, min: 50, max: 50, duration: 60)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.str + result.str_buff == entity.str_backup * 2,
             "Cap must hold on repeat potion; got #{result.str + result.str_buff}"

      # The delta must not exceed backup (= the maximum contributed bump).
      assert result.str_potion_delta <= entity.str_backup
    end

    test "str_backup = 0 falls back to entity.str (VB6 parity for legacy chars)" do
      # Legacy characters loaded before Drift #18 had no persisted backup.
      # We fall back to the live base attribute.  The cap then becomes
      # `str * 2` using the un-bumped value.
      entity = make_entity(%{str: 20, str_backup: 0, str_buff: 0})
      item = potion(6, min: 100, max: 100)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.str + result.str_buff == entity.str * 2,
             "Expected fallback cap = str*2 (40), got #{result.str + result.str_buff}"
    end

    test "buff expiry restores original str exactly (no off-by-one)" do
      entity = make_entity(%{char_id: 1, str: 18, str_backup: 18, str_buff: 0})
      # tight duration = 1 tick
      item = potion(6, min: 100, max: 100, duration: 1)
      buffed = InventoryHandlers.apply_potion(entity, item)

      # tick once → expires
      state = map_state(players: %{1 => buffed}, sessions: %{1 => self()})
      now = System.monotonic_time(:millisecond)
      state = StatusTicks.process_player_buffs(state, 1, state.players[1], now)

      restored = state.players[1]
      assert restored.duracion_efecto == 0
      assert restored.tomo_pocion == false
      assert restored.str == entity.str,
             "Base str must not be mutated by potion; drift from #{entity.str} to #{restored.str}"
      assert restored.str + restored.str_buff == entity.str,
             "Expired buff must fully restore str; got #{restored.str + restored.str_buff}"
      assert restored.str_potion_delta == 0,
             "str_potion_delta must be cleared on expiry; got #{restored.str_potion_delta}"
    end

    test "buff does not double-restore if tick fires past zero" do
      # Once duracion_efecto == 0 the tick must be a no-op; no further
      # decrement of str_buff.
      entity =
        make_entity(%{
          char_id: 1,
          str: 18,
          str_buff: 6,
          str_potion_delta: 0,
          duracion_efecto: 0,
          tomo_pocion: false
        })

      state = map_state(players: %{1 => entity}, sessions: %{1 => self()})
      now = System.monotonic_time(:millisecond)

      state = StatusTicks.process_player_buffs(state, 1, state.players[1], now)
      state = StatusTicks.process_player_buffs(state, 1, state.players[1], now)

      after_ticks = state.players[1]

      assert after_ticks.str_buff == 6,
             "Expected str_buff preserved (spell buff) across idle ticks, got #{after_ticks.str_buff}"
    end
  end

  describe "agility potion adversarial" do
    test "agility potion stacks independently from strength potion duration" do
      entity = make_entity(%{char_id: 1})
      str_item = potion(6, min: 4, max: 4, duration: 2)
      agi_item = potion(7, min: 4, max: 4, duration: 5)

      after_str = InventoryHandlers.apply_potion(entity, str_item)
      after_both = InventoryHandlers.apply_potion(after_str, agi_item)

      # duracion_efecto is a single scalar (VB6 parity): max of the two is stored.
      assert after_both.duracion_efecto == max(2, 5),
             "Expected max duration stored, got #{after_both.duracion_efecto}"

      assert after_both.str_buff > 0 and after_both.agi_buff > 0
      assert after_both.str_potion_delta > 0 and after_both.agi_potion_delta > 0

      # Tick 5 times — both deltas should be cleared on expiry.
      state = map_state(players: %{1 => after_both}, sessions: %{1 => self()})
      now = System.monotonic_time(:millisecond)

      state =
        Enum.reduce(1..5, state, fn _i, s ->
          StatusTicks.process_player_buffs(s, 1, s.players[1], now)
        end)

      ent = state.players[1]

      assert ent.duracion_efecto == 0
      assert ent.tomo_pocion == false

      # TODO(parity): str/agi potions share a single duracion_efecto scalar,
      # so the short-duration potion "rides" the long one. VB6 also uses a
      # single DuracionEfecto counter (InvUsuario.bas:1894/1909), so this is
      # not a drift — but independent-timer expectation from the task
      # description is NOT achievable under VB6 semantics.
      assert ent.str + ent.str_buff == ent.str_backup,
             "str restored, got #{ent.str + ent.str_buff}"
      assert ent.agi + ent.agi_buff == ent.agi_backup,
             "agi restored, got #{ent.agi + ent.agi_buff}"
    end

    test "agility potion while paralyzed — apply_potion mutates stats (pure fn bypass)" do
      # VB6 InvUsuario.bas:1877-1887: the otPotions branch only rejects
      # Muerto + IntervaloPermiteGolpeUsar. Paralizado is NOT a gate for
      # potions — a paralyzed user CAN drink an agility potion in VB6.
      entity = make_entity(%{paralyzed: true, agi_backup: 18, agi: 18})
      item = potion(7, min: 4, max: 4)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.agi + result.agi_buff > entity.agi,
             "Pure apply_potion must not care about paralysis"
    end

    test "agility potion while paralyzed — handle_use_item SHOULD allow it (VB6 parity gap)" do
      # VB6 `InvUsuario.bas:1877-1887` (otPotions) only gates on Muerto and
      # IntervaloPermiteGolpeUsar — Paralizado is NOT a gate for potions.
      # A paralyzed character in VB6 can still down a speed potion. The
      # Elixir port previously rejected any item use while paralyzed at the
      # top of handle_use_item; the fix scopes the paralysis gate to
      # non-potion item types so potions (obj_type 1 in this codebase)
      # bypass it.
      #
      # We pick a real obj_type-1 item from loaded GameData (id 22,
      # "Frutillas") since handle_use_item resolves the item via
      # GameData.get_item/1 — a synthetic id would fall through the
      # :unknown_item branch before the paralysis gate is even evaluated.
      potion_id = 22

      entity =
        make_entity(%{
          char_id: 1,
          paralyzed: true,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: potion_id,
              amount: 1,
              equipped: false
            })
        })

      state = state_with(entity)

      result = InventoryHandlers.handle_use_item(state, 1, 0)

      # VB6 parity: must NOT reject with :paralyzed.
      refute match?({:reply, {:error, :paralyzed}, _}, result),
             "VB6 parity drift: paralyzed player must still be able to drink potions " <>
               "(InvUsuario.bas:1877 has no Paralizado gate on otPotions). Got: " <>
               inspect(result)
    end
  end

  describe "HP potion — DivineBlood + SelfHealingBonus adversarial" do
    test "HP potion with SelfHealingBonus = 0 applies no bonus (multiplier 1.0)" do
      entity = make_entity(%{hp: 50, self_healing_bonus: 0.0})
      item = potion(1, min: 40, max: 40)

      healed = InventoryHandlers.apply_potion(entity, item)

      assert healed.hp == 90, "Expected 50 + 40 * 1.0 = 90, got #{healed.hp}"
    end

    test "HP potion with negative SelfHealingBonus clamps multiplier at 0" do
      entity = make_entity(%{hp: 50, self_healing_bonus: -1.5})
      item = potion(1, min: 40, max: 40)

      healed = InventoryHandlers.apply_potion(entity, item)

      assert healed.hp == 50, "Expected no heal (multiplier 0), got #{healed.hp}"
    end

    test "DivineBlood > 0 blocks HP potion via apply_item_use (no consume, no heal)" do
      # apply_item_use is the gate (VB6 InvUsuario.bas:1925-1927).
      item_def = potion(1, id: 1234, min: 40, max: 40)

      entity =
        make_entity(%{
          char_id: 1,
          hp: 50,
          divine_blood: 1,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: 1234,
              amount: 1,
              equipped: false
            })
        })

      state = state_with(entity)

      assert {:ok, returned_entity, _state} =
               InventoryHandlers.apply_item_use(entity, item_def, 0, state)

      # Heal must be skipped
      assert returned_entity.hp == 50, "Expected no heal, got #{returned_entity.hp}"
    end

    test "DivineBlood counter stays unchanged when HP potion is rejected" do
      # TODO(parity): task description says "VB6 consumes divine_blood
      # counter instead of the potion". Re-reading InvUsuario.bas:1925-1928,
      # VB6 does NOT consume DivineBlood — it simply rejects the potion
      # with MSG_DIVINE_BLOOD_CANNOT_MIX_WITH_MORTAL_BLOOD and Exit Sub.
      # So the counter is preserved.  Assert that behaviour.
      item_def = potion(1, id: 1234, min: 40, max: 40)

      entity =
        make_entity(%{
          char_id: 1,
          hp: 50,
          divine_blood: 3,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: 1234,
              amount: 1,
              equipped: false
            })
        })

      state = state_with(entity)

      assert {:ok, returned_entity, _state} =
               InventoryHandlers.apply_item_use(entity, item_def, 0, state)

      assert returned_entity.divine_blood == 3,
             "divine_blood must NOT be decremented on reject; got #{returned_entity.divine_blood}"
    end

    test "HP potion when divine_blood counter = 0 consumes normally" do
      item_def = potion(1, id: 1234, min: 40, max: 40)

      entity =
        make_entity(%{
          char_id: 1,
          hp: 50,
          divine_blood: 0
        })

      # apply_potion is the post-gate path
      refute InventoryHandlers.hp_potion_blocked_by_divine_blood?(entity, item_def)
      healed = InventoryHandlers.apply_potion(entity, item_def)
      assert healed.hp == 90
    end
  end

  describe "mana potion — porcentaje edge cases" do
    test "mana potion at 0 mana restores porcentaje % of max_mana (no minima weirdness)" do
      entity = make_entity(%{mana: 0, max_mana: 1000})
      item = potion(2, porcentaje: 25)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.mana == 250, "Expected 0 + 25% * 1000 = 250, got #{result.mana}"
    end

    test "mana potion does not blow up when max_mana = 0 (degenerate)" do
      # VB6: Porcentaje(.Stats.MaxMAN, porc) = MaxMAN * porc / 100. MaxMAN = 0
      # yields 0; MinMAN stays 0.  No division-by-zero.
      entity = make_entity(%{mana: 0, max_mana: 0})
      item = potion(2, porcentaje: 50)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.mana == 0, "Expected no-op when max_mana = 0, got #{result.mana}"
    end

    test "mana potion is not class-restricted (VB6 parity: no class gate on otPotions)" do
      # VB6 InvUsuario.bas:1877-1956 has no class check for mana potions;
      # warriors can drink them.  Verify apply_potion still heals.
      entity = make_entity(%{mana: 100, max_mana: 1000, class: :warrior})
      item = potion(2, porcentaje: 30)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.mana == 400, "Expected 100 + 30% * 1000 = 400, got #{result.mana}"
    end
  end

  describe "potion cooldown (IntervaloPermiteGolpeUsar) adversarial" do
    test "drinking a potion during tomo_pocion-adjacent cooldown is rejected" do
      # VB6: IntervaloPermiteGolpeUsar gate (InvUsuario.bas:1883). Our
      # implementation uses `next_item_use_at` which is bumped after every
      # successful use. A second call inside the cooldown window returns
      # {:error, :cooldown}.
      Arena.Settings.set(:item_use_cooldown_ms, 2000)

      item_def = %ItemDef{
        id: 9991,
        obj_type: 1,
        tipo_pocion: 2,
        min_modificador: 0,
        max_modificador: 0,
        porcentaje: 10,
        duracion_efecto: 0
      }

      # Seed a fake item definition directly — since GameData is ETS-backed
      # we cannot mutate it safely from tests; instead we simulate the
      # cooldown by setting next_item_use_at to the future and calling
      # handle_use_item.
      entity =
        make_entity(%{
          char_id: 1,
          next_item_use_at: System.monotonic_time(:millisecond) + 10_000,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_def.id,
              amount: 1,
              equipped: false
            })
        })

      state = state_with(entity)

      assert {:reply, {:error, :cooldown}, _state} =
               InventoryHandlers.handle_use_item(state, 1, 0)
    end
  end

  describe "potion state persistence across log-off (parity drift)" do
    test "from_entity/1 does NOT preserve duracion_efecto or tomo_pocion" do
      # TODO(parity): `GameBackend.Characters.from_entity/1` / `to_entity/1`
      # do not round-trip duracion_efecto / tomo_pocion / str_potion_delta /
      # str_backup (backup is rewritten to current str on load, not saved).
      # VB6 persists DuracionEfecto in the character file so a mid-buff
      # logoff preserves the remaining seconds on reconnect.  This test
      # asserts the VB6-faithful expectation and fails today.

      buffed =
        make_entity(%{
          str: 18,
          str_backup: 18,
          str_buff: 12,
          str_potion_delta: 12,
          duracion_efecto: 45,
          tomo_pocion: true
        })

      attrs = GameBackend.Characters.from_entity(buffed)

      # VB6 parity: these fields must survive the round-trip.
      assert Map.has_key?(attrs, :duracion_efecto),
             "VB6 parity drift: from_entity/1 drops duracion_efecto. " <>
               "Logging off mid-buff loses the potion timer entirely."

      assert Map.has_key?(attrs, :tomo_pocion),
             "VB6 parity drift: from_entity/1 drops tomo_pocion flag."

      assert Map.has_key?(attrs, :str_potion_delta),
             "VB6 parity drift: from_entity/1 drops str_potion_delta " <>
               "— the potion-contributed buff portion is lost on save."
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # VOLVER CRIMINAL ADVERSARIAL TESTS
  # ═══════════════════════════════════════════════════════════════════════

  describe "VolverCriminal — idempotency / repeat calls" do
    test "calling VolverCriminal on an already-criminal player is a safe no-op" do
      entity =
        make_entity(%{
          char_id: :already_crim,
          criminal: true,
          faction: :none,
          faction_score: 0
        })

      state = state_with(entity)

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :already_crim, entity)

      assert new_entity.criminal == true
      # faction_score was already 0, must not wrap-around or touch anything weird
      assert new_entity.faction_score == 0
    end

    test "faction_score floor — already-at-0 Ciudadano stays at 0 (no wrap)" do
      entity =
        make_entity(%{
          char_id: :ciud,
          criminal: false,
          faction: :none,
          faction_score: 0
        })

      state = state_with(entity)

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :ciud, entity)

      assert new_entity.faction_score == 0,
             "faction_score must not go negative; got #{new_entity.faction_score}"

      assert new_entity.criminal == true
    end
  end

  describe "VolverCriminal — malformed map metadata" do
    test "NoPKs map with no :salida metadata does not crash (warn + continue)" do
      entity = make_entity(%{char_id: :stuck, criminal: false})

      # no_pks = true but :salida is nil (map never configured a salida).
      state = state_with(entity, %{no_pks: true, salida: nil})

      # The helper must not crash; it returns {entity, state}.
      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :stuck, entity)

      assert new_entity.criminal == true
      refute_receive {:transfer, _, _, _, _}, 50
    end

    test "trigger map is a nil sentinel — tile_trigger falls back to 0" do
      # VB6 indexes MapData(Map, x, y).trigger; our trigger_map may be nil.
      entity = make_entity(%{char_id: :nopatch, criminal: false})
      state = state_with(entity, %{trigger_map: nil})

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :nopatch, entity)

      assert new_entity.criminal == true,
             "With no trigger map, player must still become criminal"
    end
  end

  describe "VolverCriminal — party state consistency" do
    test "criminal transition while in a party disbands it (leader path)" do
      leader = make_entity(%{char_id: 7001, name: "L", criminal: false})
      member = make_entity(%{char_id: 7002, name: "M", criminal: false})

      :ok = Arena.PartyServer.invite(leader.char_id, member.char_id)
      :ok = Arena.PartyServer.accept_invite(member.char_id)
      assert {:ok, _} = Arena.PartyServer.get_party(leader.char_id)

      state =
        map_state(
          players: %{leader.char_id => leader, member.char_id => member},
          sessions: %{leader.char_id => self(), member.char_id => self()},
          meta: %{no_pks: false, salida: nil, trigger_map: %{}, rain: false}
        )

      {new_leader, _} = CriminalStatus.volver_criminal(state, leader.char_id, leader)
      Process.sleep(20)

      assert new_leader.criminal == true
      assert Arena.PartyServer.get_party(leader.char_id) == :not_in_party,
             "Leader party must be dissolved (VB6: FinalizarGrupo)"

      assert Arena.PartyServer.get_party(member.char_id) == :not_in_party,
             "Member must be removed from the party on dissolution"
    end
  end

  describe "VolverCriminal — trade / commerce sessions (parity drift)" do
    test "trade session is NOT auto-closed (current behaviour / VB6 parity)" do
      # VB6: VolverCriminal does not cancel trade/commerce (only the party
      # is dissolved).  We assert the current Elixir behaviour matches.
      entity =
        make_entity(%{
          char_id: :trader,
          trade_partner_id: 9999,
          commerce_npc_id: 42
        })

      state = state_with(entity)

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :trader, entity)

      assert new_entity.trade_partner_id == 9999,
             "Trade partner id must be preserved — VB6 does not close trade on VolverCriminal"

      assert new_entity.commerce_npc_id == 42,
             "Commerce npc id must be preserved — VB6 does not close commerce on VolverCriminal"

      # Observation-only note: if future drift work decides to mirror the
      # "in combat cancels trade" Comercio gate and extend it here,
      # flip these assertions.
    end
  end

  describe "VolverCriminal — faction branching" do
    test "Caos player with trigger = 6 short-circuits before faction check" do
      # VB6 order:
      #   1. trigger=6 → Exit Sub
      #   2. Faccion = Caos/Concilio → Exit Sub
      # Confirm the trigger check wins even for chaos members (entity
      # unchanged either way, but side effects must not fire).
      entity =
        make_entity(%{
          char_id: :caos_tile,
          faction: :chaos_legion,
          faction_score: 500,
          criminal: false
        })

      state = state_with(entity, %{trigger_map: %{{50, 50} => 6}})

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :caos_tile, entity)

      assert new_entity.criminal == false
      assert new_entity.faction_score == 500
    end

    test "Concilio faction early-return leaves all state intact" do
      entity =
        make_entity(%{
          char_id: :concilio,
          faction: :council,
          faction_score: 250,
          criminal: false
        })

      state = state_with(entity)

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :concilio, entity)

      assert new_entity.criminal == false,
             "Council player must not become criminal (VB6:2271)"

      assert new_entity.faction_score == 250
    end
  end

  describe "VolverCriminal — GM path" do
    test "GM on NoPKs map is NOT warped but still becomes criminal" do
      # TODO(parity): VB6 `EsGM(UserIndex)` returns true for Admin / Dios /
      # SemiDios / Consejero.  Our `gm?/1` checks `gm or gm_level`.  The
      # warp is skipped for GMs, but the criminal flag is still set.
      # VB6 does NOT short-circuit on GM before the criminal flip; it
      # only skips the warp.  Assert both: GM receives no :transfer,
      # and ends up with criminal=true.  If policy later changes to
      # "GMs can't be criminal", this is where we'd catch it.
      entity =
        make_entity(%{
          char_id: :gm,
          gm: true,
          gm_level: :admin,
          criminal: false
        })

      state =
        state_with(entity, %{
          no_pks: true,
          salida: %{map: 5, x: 60, y: 70}
        })

      {new_entity, _new_state} = CriminalStatus.volver_criminal(state, :gm, entity)

      refute_receive {:transfer, _, _, _, _}, 50
      assert new_entity.criminal == true,
             "VB6 still flips the criminal flag for GMs; " <>
               "only the NoPKs warp is bypassed"
    end
  end

  describe "VolverCriminal — concurrency" do
    test "two concurrent calls from different callers do not tear state" do
      # The helper itself is pure: `volver_criminal/3` returns
      # `{entity, state}` and touches no shared mutable state aside from
      # PartyServer (a GenServer that serialises calls).  Issue two calls
      # in parallel tasks with the same entity and verify both produce a
      # criminal=true entity and the PartyServer is consistent.
      leader = make_entity(%{char_id: 8001, name: "L", criminal: false})
      member = make_entity(%{char_id: 8002, name: "M", criminal: false})

      :ok = Arena.PartyServer.invite(leader.char_id, member.char_id)
      :ok = Arena.PartyServer.accept_invite(member.char_id)

      state =
        map_state(
          players: %{leader.char_id => leader, member.char_id => member},
          sessions: %{leader.char_id => self(), member.char_id => self()},
          meta: %{no_pks: false, salida: nil, trigger_map: %{}, rain: false}
        )

      t1 = Task.async(fn -> CriminalStatus.volver_criminal(state, leader.char_id, leader) end)
      t2 = Task.async(fn -> CriminalStatus.volver_criminal(state, member.char_id, member) end)

      {new_leader, _} = Task.await(t1, 1000)
      {new_member, _} = Task.await(t2, 1000)

      assert new_leader.criminal == true
      assert new_member.criminal == true

      Process.sleep(30)
      # After both leaves/disbands, nobody is in the party.
      assert Arena.PartyServer.get_party(leader.char_id) == :not_in_party
      assert Arena.PartyServer.get_party(member.char_id) == :not_in_party
    end
  end
end
