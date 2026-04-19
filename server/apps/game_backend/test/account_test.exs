defmodule GameBackend.AccountTest do
  use ExUnit.Case, async: true

  alias GameBackend.Account

  describe "user_tier/1" do
    test "maps legacy VB6 patron ids to online user tiers" do
      assert Account.user_tier(0) == :normal
      assert Account.user_tier(6_057_393) == :adventurer
      assert Account.user_tier(6_057_394) == :hero
      assert Account.user_tier(6_057_395) == :legend
      assert Account.user_tier(999_999) == :normal
    end

    test "reads user tier from account structs" do
      assert Account.user_tier(%Account{is_active_patron: 6_057_393}) == :adventurer
      assert Account.user_tier(%Account{is_active_patron: 0}) == :normal
    end
  end
end
