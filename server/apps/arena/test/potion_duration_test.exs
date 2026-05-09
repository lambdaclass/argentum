defmodule Arena.PotionDurationTest do
  @moduledoc """
  Drift #18 — Strength (tipo_pocion == 6) and Agility (tipo_pocion == 7)
  potions must:

  1. Clamp the bumped attribute at `backup * 2`, where `backup` is the
     character's base attribute (VB6: `Stats.UserAtributosBackUP`).
     VB6: `InvUsuario.bas:1893-1922`,
          `.Stats.UserAtributos(attr) = MinimoInt(Atr + rnd, BackUP * 2)`.

  2. Store a `duracion_efecto` countdown and a `tomo_pocion` flag on the
     entity so the buff expires.  VB6: `General.bas:1278-1297`
     (`DuracionPociones`) decrements the counter once per second and,
     when it hits zero, restores the live attribute from its BackUP and
     clears TomoPocion.

  The tick runs in the 1 s `process_player_buffs` path in `StatusTicks`,
  alongside every other VB6 per-second expirable buff.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.InventoryHandlers
  alias Arena.Map.StatusTicks
  alias Arena.Data.ItemDef
  alias AoEntities.PlayerEntity
  import Arena.Test.MapStateFactory

  defp potion(tipo, min, max, duration \\ 60) do
    %ItemDef{
      tipo_pocion: tipo,
      min_modificador: min,
      max_modificador: max,
      duracion_efecto: duration
    }
  end

  defp strength_entity(opts \\ []) do
    %PlayerEntity{
      char_id: Keyword.get(opts, :char_id, 1),
      str: Keyword.get(opts, :str, 18),
      agi: Keyword.get(opts, :agi, 18),
      str_backup: Keyword.get(opts, :str_backup, 18),
      agi_backup: Keyword.get(opts, :agi_backup, 18),
      str_buff: 0,
      agi_buff: 0,
      duracion_efecto: 0,
      tomo_pocion: false,
      buffs: []
    }
  end

  describe "Drift #18 — strength potion (tipo_pocion == 6) clamp" do
    test "strength bump is clamped at str_backup * 2 on a very large roll" do
      entity = strength_entity(str: 18, str_backup: 18)
      # huge constant bump so we know it would exceed 2x without the clamp
      item = potion(6, 100, 100)

      result = InventoryHandlers.apply_potion(entity, item)

      # VB6: UserAtributos(Fuerza) = MinimoInt(18 + 100, 18 * 2) = 36
      # Expressed in terms of buff: effective = str + str_buff <= str_backup * 2
      assert result.str + result.str_buff == entity.str_backup * 2,
             "Expected str+str_buff clamped to #{entity.str_backup * 2}, got #{result.str + result.str_buff}"
    end

    test "stacking two potions does not push past the cap" do
      entity = strength_entity(str: 18, str_backup: 18)
      item = potion(6, 100, 100)

      once = InventoryHandlers.apply_potion(entity, item)
      twice = InventoryHandlers.apply_potion(once, item)

      assert twice.str + twice.str_buff == entity.str_backup * 2
    end

    test "duracion_efecto and tomo_pocion are set when potion applies" do
      entity = strength_entity()
      item = potion(6, 2, 2, 30)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.tomo_pocion == true
      assert result.duracion_efecto == 30
    end
  end

  describe "Drift #18 — agility potion (tipo_pocion == 7) clamp" do
    test "agility bump is clamped at agi_backup * 2" do
      entity = strength_entity(agi: 18, agi_backup: 18)
      item = potion(7, 100, 100)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.agi + result.agi_buff == entity.agi_backup * 2
    end

    test "duracion_efecto and tomo_pocion set on agility potion" do
      entity = strength_entity()
      item = potion(7, 2, 2, 40)

      result = InventoryHandlers.apply_potion(entity, item)

      assert result.tomo_pocion == true
      assert result.duracion_efecto == 40
    end
  end

  describe "Drift #18 — DuracionPociones tick restores attributes" do
    test "duration ticks down each buff tick" do
      entity = strength_entity(char_id: 1)
      item = potion(6, 4, 4, 3)
      buffed = InventoryHandlers.apply_potion(entity, item)

      assert buffed.duracion_efecto == 3

      state = map_state(players: %{1 => buffed})
      now = System.monotonic_time(:millisecond)

      {state, _effects} = StatusTicks.process_player_buffs(state, 1, state.players[1], now)
      assert state.players[1].duracion_efecto == 2
      assert state.players[1].tomo_pocion == true

      {state, _effects} = StatusTicks.process_player_buffs(state, 1, state.players[1], now)
      assert state.players[1].duracion_efecto == 1
      assert state.players[1].tomo_pocion == true
    end

    test "on expiry (duration hits 0) attribute is restored and tomo_pocion is cleared" do
      entity = strength_entity(char_id: 1, str: 18, str_backup: 18)
      item = potion(6, 100, 100, 1)
      buffed = InventoryHandlers.apply_potion(entity, item)

      # Sanity: we actually got a buff on top of the base str
      assert buffed.str + buffed.str_buff > buffed.str_backup

      state = map_state(players: %{1 => buffed})
      now = System.monotonic_time(:millisecond)

      {state, _effects} = StatusTicks.process_player_buffs(state, 1, state.players[1], now)

      restored = state.players[1]
      assert restored.duracion_efecto == 0
      assert restored.tomo_pocion == false,
             "tomo_pocion must be cleared on expiry, got #{inspect(restored.tomo_pocion)}"
      # VB6: UserAtributos = UserAtributosBackUP on expiry.
      assert restored.str + restored.str_buff == restored.str_backup,
             "Expected str+str_buff restored to backup (#{restored.str_backup}), got #{restored.str + restored.str_buff}"
    end

    test "agility potion expiry restores agi and clears tomo_pocion" do
      entity = strength_entity(char_id: 1, agi: 18, agi_backup: 18)
      item = potion(7, 100, 100, 1)
      buffed = InventoryHandlers.apply_potion(entity, item)

      state = map_state(players: %{1 => buffed})
      now = System.monotonic_time(:millisecond)
      {state, _effects} = StatusTicks.process_player_buffs(state, 1, state.players[1], now)
      restored = state.players[1]

      assert restored.tomo_pocion == false
      assert restored.duracion_efecto == 0
      assert restored.agi + restored.agi_buff == restored.agi_backup
    end
  end
end
