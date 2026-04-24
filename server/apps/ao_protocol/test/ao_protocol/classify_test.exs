defmodule AoProtocol.ClassifyTest do
  use ExUnit.Case, async: true

  alias AoProtocol.Classify
  alias AoProtocol.PacketIds.Server, as: S

  describe "lossy" do
    for fun <- [:character_move, :create_fx, :play_wave, :play_midi,
                :rain_toggle, :snow_toggle, :pause_toggle, :area_changed] do
      test "#{fun}/0 is lossy" do
        assert Classify.class_for(apply(S, unquote(fun), [])) == :lossy
      end
    end
  end

  describe "coalesce" do
    for fun <- [:update_hp, :update_mana, :update_sta, :update_gold, :update_exp,
                :update_hunger_and_thirst, :update_user_stats, :mini_stats, :pos_update] do
      test "#{fun}/0 is coalesce" do
        assert Classify.class_for(apply(S, unquote(fun), [])) == :coalesce
      end
    end
  end

  describe "critical (default)" do
    test "chat / combat / inventory / commerce are critical" do
      assert Classify.class_for(S.chat_over_head()) == :critical
      assert Classify.class_for(S.console_msg()) == :critical
      assert Classify.class_for(S.char_swing()) == :critical
      assert Classify.class_for(S.change_inventory_slot()) == :critical
      assert Classify.class_for(S.commerce_init()) == :critical
      assert Classify.class_for(S.bank_init()) == :critical
    end

    test "character create/remove are critical — players must not be ghosts" do
      assert Classify.class_for(S.character_create()) == :critical
      assert Classify.class_for(S.character_remove()) == :critical
    end

    test "unknown IDs default to :critical (must-deliver)" do
      assert Classify.class_for(9999) == :critical
    end
  end
end
