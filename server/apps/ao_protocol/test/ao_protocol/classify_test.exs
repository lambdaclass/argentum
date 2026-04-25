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

  describe "coalesce_key_for" do
    test "coalesce-class packets return their packet_id as the key" do
      for fun <- [:update_hp, :update_mana, :update_sta, :update_gold, :update_exp,
                  :update_hunger_and_thirst, :update_user_stats, :mini_stats, :pos_update] do
        id = apply(S, fun, [])
        assert Classify.coalesce_key_for(id) == id,
               "#{fun}/0 should use its packet_id as the coalesce key"
      end
    end

    test "lossy and critical packets return nil (no coalesce key)" do
      assert Classify.coalesce_key_for(S.character_move()) == nil
      assert Classify.coalesce_key_for(S.console_msg()) == nil
      assert Classify.coalesce_key_for(S.character_create()) == nil
      assert Classify.coalesce_key_for(9999) == nil
    end

    test "different coalesce streams have distinct keys" do
      # Each stat stream gets its own slot — HP updates do not collapse mana
      # updates, etc.
      keys =
        for fun <- [:update_hp, :update_mana, :update_sta, :update_gold,
                    :update_exp, :update_hunger_and_thirst, :update_user_stats,
                    :mini_stats, :pos_update] do
          Classify.coalesce_key_for(apply(S, fun, []))
        end

      assert length(Enum.uniq(keys)) == length(keys),
             "every coalesce-class packet must have a distinct key"
    end
  end
end
