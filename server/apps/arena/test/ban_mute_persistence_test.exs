defmodule Arena.BanMutePersistenceTest do
  @moduledoc """
  Persistence tests for ban and mute state.

  Covers Account.ban/unban/banned? round-trips, ban expiration
  semantics, character muted_until field persistence across
  save/load cycles, and mute expiration detection.

  Uses direct Ecto/context calls against a sandboxed Postgres connection.
  No TCP connections required.
  """

  use ExUnit.Case, async: false

  alias GameBackend.Repo
  alias GameBackend.Characters
  alias GameBackend.Account

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)

    {:ok, account} = Account.create("banmuteuser_#{System.unique_integer([:positive])}", "password123")

    %{account: account}
  end

  defp create_character(account, name_suffix \\ "") do
    name = "BmChar#{System.unique_integer([:positive])}#{name_suffix}"

    {:ok, char} =
      Characters.create(%{
        name: name,
        account_id: account.id
      })

    char
  end

  # ---- Ban persistence ----

  describe "Account.ban sets banned_until and Account.banned? returns true" do
    test "banning an account with future datetime persists", %{account: account} do
      ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Account.ban(account.id, ban_until)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == true
      assert reloaded.banned_until != nil
    end

    test "ban persists and is detectable on fresh DB load", %{account: account} do
      ban_until = DateTime.add(DateTime.utc_now(), 7200, :second)
      {:ok, _} = Account.ban(account.id, ban_until)

      # Simulate a fresh login check — load from DB
      loaded = Repo.get(Account, account.id)
      assert Account.banned?(loaded) == true
    end
  end

  describe "Account.unban clears banned_until, Account.banned? returns false" do
    test "unbanning after ban clears the ban", %{account: account} do
      ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Account.ban(account.id, ban_until)
      {:ok, _} = Account.unban(account.id)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == false
      assert reloaded.banned_until == nil
    end

    test "unbanning a never-banned account is a no-op (still not banned)", %{account: account} do
      {:ok, _} = Account.unban(account.id)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == false
    end
  end

  describe "ban with future datetime is banned; ban with past datetime is not banned" do
    test "future ban_until → banned", %{account: account} do
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)
      {:ok, _} = Account.ban(account.id, future)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == true
    end

    test "past ban_until → not banned (expired)", %{account: account} do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, _} = Account.ban(account.id, past)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == false
    end

    test "ban exactly now (edge) → not banned (DateTime.compare returns :eq, not :gt)", %{account: account} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = Account.ban(account.id, now)

      reloaded = Repo.get(Account, account.id)
      # banned? checks until > now, so exactly equal is not banned
      assert Account.banned?(reloaded) == false
    end
  end

  describe "ban not_found error" do
    test "banning a non-existent account returns error" do
      assert {:error, :not_found} = Account.ban(-1, DateTime.add(DateTime.utc_now(), 3600, :second))
    end

    test "unbanning a non-existent account returns error" do
      assert {:error, :not_found} = Account.unban(-1)
    end
  end

  # ---- Mute persistence ----

  describe "character muted_until field persists across save/load" do
    test "setting muted_until on character survives save and reload", %{account: account} do
      char = create_character(account)

      mute_expiry = System.os_time(:second) + 3600
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: mute_expiry})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == mute_expiry
    end

    test "muted_until round-trips through entity conversion", %{account: account} do
      char = create_character(account)

      mute_expiry = System.os_time(:second) + 7200
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: mute_expiry})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)
      assert entity.muted_until == mute_expiry

      attrs = Characters.from_entity(entity)
      assert attrs.muted_until == mute_expiry
    end

    test "zero muted_until means not muted (default)", %{account: account} do
      char = create_character(account)

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == 0

      entity = Characters.to_entity(reloaded)
      assert entity.muted_until == 0
    end

    test "updating muted_until overwrites previous value", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: 1000})
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: 2000})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == 2000
    end
  end

  describe "mute expiration: muted_until in the past means no longer muted" do
    test "future muted_until → muted", %{account: account} do
      char = create_character(account)

      future_ts = System.os_time(:second) + 3600
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: future_ts})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)

      # The chat handler checks: entity.muted_until > System.os_time(:second)
      assert entity.muted_until > System.os_time(:second)
    end

    test "past muted_until → no longer muted", %{account: account} do
      char = create_character(account)

      past_ts = System.os_time(:second) - 3600
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: past_ts})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)

      # Expired mute: muted_until is in the past
      assert entity.muted_until < System.os_time(:second)
    end

    test "clearing mute by setting muted_until to 0 persists", %{account: account} do
      char = create_character(account)

      # Mute then unmute
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: System.os_time(:second) + 3600})
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: 0})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == 0

      entity = Characters.to_entity(reloaded)
      assert entity.muted_until == 0
    end
  end

  # ---- GM /BAN command persists ban via Account context ----

  describe "GM /BAN command persists ban via Account context" do
    test "gm_ban calls Account.ban which persists to DB", %{account: account} do
      # The GM /BAN command (Arena.Map.Gm.Moderation.gm_ban) calls
      # GameBackend.Account.ban(target.account_id, banned_until).
      # We verify the persistence layer directly: the same Account.ban
      # call the GM command uses persists correctly.
      days = 3
      banned_until = DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)

      {:ok, _} = Account.ban(account.id, banned_until)

      # Verify persistence: reload from DB like login would
      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == true

      # The ban_until should be approximately `days` days from now
      diff_seconds = DateTime.diff(reloaded.banned_until, DateTime.utc_now(), :second)
      assert diff_seconds > (days * 24 * 3600 - 10)
      assert diff_seconds <= days * 24 * 3600
    end
  end

  # ---- GM /MUTE command persists mute ----

  describe "GM /MUTE command persists mute" do
    test "gm_mute sets muted_until on entity; save_snapshot persists it", %{account: account} do
      char = create_character(account)

      # The GM /MUTE command (Arena.Map.Gm.Moderation.gm_mute) sets:
      #   muted_until = System.system_time(:millisecond) + minutes * 60_000
      # on the in-memory entity. When the periodic snapshot runs,
      # save_snapshot persists it. We verify that chain.
      minutes = 10
      muted_until = System.system_time(:millisecond) + minutes * 60_000

      # Simulate what the map server does on periodic snapshot
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: muted_until})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == muted_until

      entity = Characters.to_entity(reloaded)
      assert entity.muted_until == muted_until
    end

    test "unmute via setting muted_until to 0 persists across snapshot", %{account: account} do
      char = create_character(account)

      # Mute
      muted_until = System.system_time(:millisecond) + 600_000
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: muted_until})

      # Unmute (GM /UNMUTE sets muted_until: 0 on entity, then snapshot persists)
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: 0})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == 0
    end
  end

  # ---- Combined ban + mute scenario ----

  describe "combined ban and mute scenario" do
    test "account can be banned and character muted independently", %{account: account} do
      char = create_character(account)

      # Ban the account
      ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Account.ban(account.id, ban_until)

      # Mute the character
      mute_expiry = System.os_time(:second) + 1800
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: mute_expiry})

      # Verify both persist independently
      reloaded_account = Repo.get(Account, account.id)
      assert Account.banned?(reloaded_account) == true

      reloaded_char = Characters.get(char.id)
      assert reloaded_char.muted_until == mute_expiry

      # Unban account — mute should remain
      {:ok, _} = Account.unban(account.id)

      reloaded_account2 = Repo.get(Account, account.id)
      assert Account.banned?(reloaded_account2) == false

      reloaded_char2 = Characters.get(char.id)
      assert reloaded_char2.muted_until == mute_expiry
    end
  end
end
