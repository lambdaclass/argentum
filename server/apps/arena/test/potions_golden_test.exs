defmodule Arena.PotionsGoldenTest do
  @moduledoc """
  Golden fixture for the potion flow, written against the deterministic
  scenario harness (`Arena.Test.Scenario`).

  Covers `Arena.Map.InventoryHandlers.handle_use_item/3` end-to-end for
  every `tipo_pocion` branch in `apply_potion/2` (HP, mana, stamina,
  strength, agility, poison-cure, paralysis-cure) and the
  `Arena.Map.StatusTicks.process_player_buffs/4` expiry path that
  restores attributes on `duracion_efecto` zero-out.

  Historical deterministic-parity golden work recorded in the root
  `CHANGELOG.md` — sibling of `healing_golden_test.exs`
  and `forgive_golden_test.exs`.

  VB6 anchors (lines confirmed against `Arena.Map.InventoryHandlers` /
  `Arena.Map.StatusTicks` port comments; no VB6 source tree is vendored):
    * otPotions dispatch  — InvUsuario.bas:1877-1887 (`handle_use_item/3` →
                            `apply_potion/2`; inventory_handlers.ex:459).
    * HP potion (tipo 1)  — InvUsuario.bas:1923-1945; `DivineBlood > 0` blocks
                            HP potions (InvUsuario.bas:1925; inventory_handlers.ex:679).
    * Mana potion (tipo 2)— InvUsuario.bas:1946-1956 (`Porcentaje`-scaled).
    * Stamina (tipo 4)    — InvUsuario.bas (stamina branch).
    * Strength (tipo 6)   — InvUsuario.bas:1908-1922.
    * Agility (tipo 7)    — InvUsuario.bas:1893-1907.
    * Poison-cure (tipo 5)/ Paralysis-cure (tipo 8) — InvUsuario.bas:1983/2149
                            (`WriteParalizeOK`; inventory_handlers.ex:687).
    * Buff expiry         — General.bas:1278-1297 `DuracionPociones`
                            (`StatusTicks.process_player_buffs/4`,
                            attribute restore on `duracion_efecto` zero-out).
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, ItemDef}
  alias Arena.Map.InventoryHandlers

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  # Item ids for the test-only potion fixtures we seed into ETS.
  @hp_potion_id 9001
  @mana_potion_id 9002
  @stamina_potion_id 9004
  @strength_potion_id 9006
  @agility_potion_id 9007
  @poison_cure_potion_id 9005
  @paralysis_cure_potion_id 9008

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Arena.Settings.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    # Item-use cooldown is read at handler time via Arena.Settings; we keep
    # it small (default) but reset between tests so a scenario that bumps
    # next_item_use_at doesn't leak.
    Arena.Settings.reset_all()

    # Seed deterministic potion fixtures. min_modificador == max_modificador
    # so the random roll inside apply_potion is a fixed value.
    seed_item(@hp_potion_id, %{tipo_pocion: 1, min_modificador: 30, max_modificador: 30})
    seed_item(@mana_potion_id, %{tipo_pocion: 2, porcentaje: 50})
    seed_item(@stamina_potion_id, %{tipo_pocion: 4, min_modificador: 25, max_modificador: 25})

    seed_item(@strength_potion_id, %{
      tipo_pocion: 6,
      min_modificador: 4,
      max_modificador: 4,
      duracion_efecto: 3
    })

    seed_item(@agility_potion_id, %{
      tipo_pocion: 7,
      min_modificador: 4,
      max_modificador: 4,
      duracion_efecto: 3
    })

    seed_item(@poison_cure_potion_id, %{tipo_pocion: 5})
    seed_item(@paralysis_cure_potion_id, %{tipo_pocion: 8})

    :ok
  end

  defp seed_item(id, fields) do
    base = %ItemDef{id: id, obj_type: 1}
    item_def = struct!(ItemDef, Map.merge(Map.from_struct(base), fields))
    :ets.insert(:arena_game_data, {{:item, id}, item_def})
  end

  defp with_potion(scenario, char_id, item_id, slot \\ 0) do
    update_state(scenario, fn state ->
      entity = state.players[char_id]

      inventory =
        List.replace_at(
          entity.inventory,
          slot,
          %{item_id: item_id, amount: 1, equipped: false}
        )

      players = Map.put(state.players, char_id, %{entity | inventory: inventory})
      %{state | players: players}
    end)
  end

  defp use_item(scenario, char_id, slot \\ 0) do
    run(scenario, fn state -> InventoryHandlers.handle_use_item(state, char_id, slot) end)
  end

  # ────────────────────────────────────────────────────────────────────
  # HP potion (tipo_pocion == 1)
  # ────────────────────────────────────────────────────────────────────

  describe "HP potion" do
    test "below max HP: heals by min_modificador, emits update_hp + change_inventory_slot" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      assert entity(s, :p).hp == 80, "VB6: 50 + 30*1.0 = 80"
      assert_effect(s, :send, to: :p, packet: :update_hp)
      assert_effect(s, :send, to: :p, packet: :change_inventory_slot)

      # Byte-level fixture: eUpdateHP (27) — MinHp(Int16) + shield(Int32).
      # The encoded HP must match the post-potion value (80), not just the id.
      assert <<27::little-signed-16, 80::little-signed-16, _shield::little-signed-32>> =
               assert_payload(s, :send, to: :p, packet: :update_hp)
    end

    test "heal is clamped at max_hp" do
      s =
        new()
        |> with_player(:p, hp: 90, max_hp: 100)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      assert entity(s, :p).hp == 100, "30-point heal clamped to max_hp"
    end

    test "potion is consumed (inventory slot cleared) on use" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      slot_0 = Enum.at(entity(s, :p).inventory, 0)
      assert slot_0 == nil, "potion must be consumed on successful use"
    end

    test "dead player: rejected, no inventory change, no update_hp" do
      s =
        new()
        |> with_player(:p, dead: true, hp: 0, max_hp: 100)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      assert entity(s, :p).hp == 0
      slot_0 = Enum.at(entity(s, :p).inventory, 0)
      assert slot_0 != nil, "dead player must not consume the potion"
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "DivineBlood > 0: HP potion blocked, console msg sent, item NOT consumed" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100, divine_blood: 1)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      assert e.hp == 50, "VB6: divine blood rejection skips heal"
      assert e.divine_blood == 1, "divine_blood counter must NOT decrement on reject"
      assert Enum.at(e.inventory, 0) != nil, "rejected potion must NOT be consumed"
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Mana potion (tipo_pocion == 2)
  # ────────────────────────────────────────────────────────────────────

  describe "mana potion" do
    test "restores porcentaje % of max_mana, emits update_mana" do
      s =
        new()
        |> with_player(:p, mana: 100, max_mana: 1000)
        |> with_potion(:p, @mana_potion_id)
        |> use_item(:p)

      assert entity(s, :p).mana == 600, "VB6: 100 + 50% of 1000 = 600"
      assert_effect(s, :send, to: :p, packet: :update_mana)

      # Byte-level fixture: eUpdateMana (26) — MinMAN(Int16).
      assert <<26::little-signed-16, 600::little-signed-16>> =
               assert_payload(s, :send, to: :p, packet: :update_mana)
    end

    test "restore is clamped at max_mana" do
      s =
        new()
        |> with_player(:p, mana: 800, max_mana: 1000)
        |> with_potion(:p, @mana_potion_id)
        |> use_item(:p)

      assert entity(s, :p).mana == 1000, "800 + 500 clamped to 1000"
    end

    test "VB6 parity: mana potion is not class-restricted (warrior accepted)" do
      s =
        new()
        |> with_player(:p, class: :warrior, mana: 0, max_mana: 200)
        |> with_potion(:p, @mana_potion_id)
        |> use_item(:p)

      assert entity(s, :p).mana == 100
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Stamina potion (tipo_pocion == 4)
  # ────────────────────────────────────────────────────────────────────

  describe "stamina potion" do
    test "below max: restores by min_modificador, emits update_sta follow-up" do
      s =
        new()
        |> with_player(:p, stamina: 50, max_stamina: 100)
        |> with_potion(:p, @stamina_potion_id)
        |> use_item(:p)

      assert entity(s, :p).stamina == 75
      assert_effect(s, :send, to: :p, packet: :update_sta)

      # Byte-level fixture: eUpdateSta (25) — MinSta(Int16).
      assert <<25::little-signed-16, 75::little-signed-16>> =
               assert_payload(s, :send, to: :p, packet: :update_sta)
    end

    test "restore is clamped at max_stamina" do
      s =
        new()
        |> with_player(:p, stamina: 90, max_stamina: 100)
        |> with_potion(:p, @stamina_potion_id)
        |> use_item(:p)

      assert entity(s, :p).stamina == 100
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Strength potion (tipo_pocion == 6)
  # ────────────────────────────────────────────────────────────────────

  describe "strength potion" do
    test "raises str_buff, sets duracion_efecto + tomo_pocion + str_potion_delta" do
      s =
        new()
        |> with_player(:p, str: 18, str_backup: 18)
        |> with_potion(:p, @strength_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      assert e.str == 18, "base str must NOT mutate"
      assert e.str_buff == 4
      assert e.str_potion_delta == 4
      assert e.tomo_pocion == true
      assert e.duracion_efecto == 3
    end

    test "bumped str clamps at str_backup * 2" do
      # min_modificador = 4 from the seed, so we use a custom huge bump.
      seed_item(8888, %{
        tipo_pocion: 6,
        min_modificador: 100,
        max_modificador: 100,
        duracion_efecto: 5
      })

      s =
        new()
        |> with_player(:p, str: 18, str_backup: 18)
        |> with_potion(:p, 8888)
        |> use_item(:p)

      e = entity(s, :p)
      # VB6: MinimoInt(18 + 100, 18 * 2) = 36
      assert e.str + e.str_buff == e.str_backup * 2
    end

    test "stack semantics: drinking strength potion twice does not exceed backup*2" do
      seed_item(8881, %{
        tipo_pocion: 6,
        min_modificador: 30,
        max_modificador: 30,
        duracion_efecto: 5
      })

      s =
        new()
        |> set_clock(1_000_000)
        |> with_player(:p, str: 18, str_backup: 18)
        |> with_potion(:p, 8881, 0)
        # apply potion #1 from slot 0; then put a fresh potion at slot 1 and drink that.
        |> use_item(:p, 0)

      after_first = entity(s, :p)
      assert after_first.str + after_first.str_buff == after_first.str_backup * 2

      s2 =
        s
        # Advance past the item-use cooldown so the second drink isn't silently
        # rejected at the gate.
        |> advance_clock(10_000)
        |> with_potion(:p, 8881, 1)
        |> use_item(:p, 1)

      e = entity(s2, :p)
      assert e.str + e.str_buff == e.str_backup * 2,
             "second drink must NOT push past the cap"
      assert e.str_potion_delta <= e.str_backup,
             "potion delta cannot exceed backup contribution"
    end

    test "stack semantics: duracion_efecto stores the MAX of stacked potions" do
      seed_item(8882, %{tipo_pocion: 6, min_modificador: 2, max_modificador: 2, duracion_efecto: 2})
      seed_item(8883, %{tipo_pocion: 6, min_modificador: 2, max_modificador: 2, duracion_efecto: 7})

      s =
        new()
        |> set_clock(1_000_000)
        |> with_player(:p, str: 18, str_backup: 18)
        |> with_potion(:p, 8882, 0)
        |> use_item(:p, 0)
        |> advance_clock(10_000)
        |> with_potion(:p, 8883, 1)
        |> use_item(:p, 1)

      assert entity(s, :p).duracion_efecto == 7,
             "VB6: duracion_efecto = max(existing, new)"
    end

    test "expiry via tick(:buff): str_buff restored, tomo_pocion cleared, delta zeroed" do
      seed_item(8884, %{
        tipo_pocion: 6,
        min_modificador: 30,
        max_modificador: 30,
        duracion_efecto: 1
      })

      s =
        new()
        |> set_clock(1_000_000)
        |> with_player(:p, str: 18, str_backup: 18)
        |> with_potion(:p, 8884)
        |> use_item(:p)

      assert entity(s, :p).tomo_pocion == true
      assert entity(s, :p).str_buff > 0

      # Buff tick decrements duracion_efecto from 1 → 0 and restores attrs.
      s = s |> advance_clock(1_000) |> tick(:buff)

      e = entity(s, :p)
      assert e.duracion_efecto == 0
      assert e.tomo_pocion == false
      assert e.str_buff == 0, "potion-contributed str_buff must be subtracted on expiry"
      assert e.str_potion_delta == 0
      assert e.str == 18, "base str must remain immutable"
    end

    test "expiry preserves concurrent spell str_buff" do
      # spell-applied str_buff coexists with potion delta; on expiry only
      # the potion delta is subtracted.
      seed_item(8885, %{
        tipo_pocion: 6,
        min_modificador: 4,
        max_modificador: 4,
        duracion_efecto: 1
      })

      s =
        new()
        |> set_clock(1_000_000)
        |> with_player(:p, str: 18, str_backup: 18, str_buff: 5)
        |> with_potion(:p, 8885)
        |> use_item(:p)

      # str_buff was 5 (spell), potion adds 4 → 9; delta = 4
      e = entity(s, :p)
      assert e.str_buff == 9
      assert e.str_potion_delta == 4

      s = s |> advance_clock(1_000) |> tick(:buff)
      restored = entity(s, :p)
      assert restored.str_buff == 5, "spell buff must survive potion expiry"
      assert restored.str_potion_delta == 0
      assert restored.tomo_pocion == false
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Agility potion (tipo_pocion == 7)
  # ────────────────────────────────────────────────────────────────────

  describe "agility potion" do
    test "raises agi_buff, sets duracion_efecto + tomo_pocion + agi_potion_delta" do
      s =
        new()
        |> with_player(:p, agi: 18, agi_backup: 18)
        |> with_potion(:p, @agility_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      assert e.agi == 18
      assert e.agi_buff == 4
      assert e.agi_potion_delta == 4
      assert e.tomo_pocion == true
      assert e.duracion_efecto == 3
    end

    test "bumped agi clamps at agi_backup * 2" do
      seed_item(8889, %{
        tipo_pocion: 7,
        min_modificador: 100,
        max_modificador: 100,
        duracion_efecto: 5
      })

      s =
        new()
        |> with_player(:p, agi: 18, agi_backup: 18)
        |> with_potion(:p, 8889)
        |> use_item(:p)

      e = entity(s, :p)
      assert e.agi + e.agi_buff == e.agi_backup * 2
    end

    test "expiry via tick(:buff): agi_buff restored, tomo_pocion cleared" do
      seed_item(8886, %{
        tipo_pocion: 7,
        min_modificador: 30,
        max_modificador: 30,
        duracion_efecto: 1
      })

      s =
        new()
        |> set_clock(1_000_000)
        |> with_player(:p, agi: 18, agi_backup: 18)
        |> with_potion(:p, 8886)
        |> use_item(:p)

      assert entity(s, :p).agi_buff > 0

      s = s |> advance_clock(1_000) |> tick(:buff)

      e = entity(s, :p)
      assert e.duracion_efecto == 0
      assert e.tomo_pocion == false
      assert e.agi_buff == 0
      assert e.agi_potion_delta == 0
    end

    test "VB6 parity: paralyzed character can still drink an agility potion" do
      # InvUsuario.bas:1877-1887 — otPotions branch has no Paralizado gate.
      s =
        new()
        |> with_player(:p, paralyzed: true, agi: 18, agi_backup: 18)
        |> with_potion(:p, @agility_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      assert e.agi_buff > 0, "potion must apply despite paralyzed"
      assert e.tomo_pocion == true
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Cure potions (tipo_pocion 5 & 8)
  # ────────────────────────────────────────────────────────────────────

  describe "poison-cure potion (tipo_pocion 5)" do
    test "clears poisoned flag and removes :poisoned buffs" do
      s =
        new()
        |> with_player(:p,
          poisoned: true,
          buffs: [
            %{type: :poisoned, expires_at: 99_999_999, next_tick: 0},
            %{type: :paralyzed, expires_at: 99_999_999}
          ]
        )
        |> with_potion(:p, @poison_cure_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      refute e.poisoned
      refute Enum.any?(e.buffs, &(&1.type == :poisoned)),
             "poison buffs must be filtered out"
      assert Enum.any?(e.buffs, &(&1.type == :paralyzed)),
             "non-poison buffs must be preserved"
    end

    test "no-op when not poisoned (still consumes the potion)" do
      s =
        new()
        |> with_player(:p, poisoned: false, buffs: [])
        |> with_potion(:p, @poison_cure_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      refute e.poisoned
      assert Enum.at(e.inventory, 0) == nil, "potion is consumed even on no-op cure"
    end
  end

  describe "paralysis-cure potion (tipo_pocion 8)" do
    test "clears paralyzed flag, emits paralize_ok packet" do
      s =
        new()
        |> with_player(:p,
          paralyzed: true,
          buffs: [%{type: :paralyzed, expires_at: 99_999_999}]
        )
        |> with_potion(:p, @paralysis_cure_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      refute e.paralyzed
      refute Enum.any?(e.buffs, &(&1.type == :paralyzed))
      assert_effect(s, :send, to: :p, packet: :paralize_ok)

      # Byte-level fixture: eParalizeOK (97) is a pure status-clear signal —
      # exactly the 2-byte id, no trailing bytes.
      assert <<97::little-signed-16>> ==
               assert_payload(s, :send, to: :p, packet: :paralize_ok)
    end

    test "no paralize_ok when player wasn't paralyzed" do
      s =
        new()
        |> with_player(:p, paralyzed: false)
        |> with_potion(:p, @paralysis_cure_potion_id)
        |> use_item(:p)

      refute_effect(s, :send, to: :p, packet: :paralize_ok)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Adversarial: cooldown + dead + empty slot
  # ────────────────────────────────────────────────────────────────────

  describe "handle_use_item rejections" do
    test "cooldown active: silent no-op, no consume, no update_hp" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:p, hp: 50, max_hp: 100, next_item_use_at: now + 10_000)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      e = entity(s, :p)
      assert e.hp == 50
      assert Enum.at(e.inventory, 0) != nil, "cooldown must NOT consume the potion"
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "empty inventory slot: silent no-op" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> use_item(:p, 5)

      assert entity(s, :p).hp == 50
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "successful use bumps next_item_use_at past `now`" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_potion(:p, @hp_potion_id)
        |> use_item(:p)

      assert entity(s, :p).next_item_use_at > now,
             "successful potion must bump next_item_use_at for cooldown"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # apply_potion/2 pure surface — tipo_pocion fall-through
  # ────────────────────────────────────────────────────────────────────

  describe "apply_potion/2 pure surface" do
    test "unknown tipo_pocion is a no-op" do
      entity = Arena.Test.PlayerFactory.player(hp: 50, max_hp: 100)

      item = %ItemDef{
        id: 9999,
        obj_type: 1,
        tipo_pocion: 99,
        min_modificador: 10,
        max_modificador: 10
      }

      result = InventoryHandlers.apply_potion(entity, item)

      assert result == entity, "unknown tipo_pocion must not mutate the entity"
    end
  end
end
