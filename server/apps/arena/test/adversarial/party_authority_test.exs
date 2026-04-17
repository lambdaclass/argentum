defmodule Arena.Adversarial.PartyAuthorityTest do
  @moduledoc """
  Adversarial tests for the PartyServer invite system.

  These tests assert correct authorization behavior. If a check is missing
  in PartyServer, the corresponding test will fail, exposing the gap.
  """

  use ExUnit.Case, async: false

  alias Arena.PartyServer

  @table :ao_parties

  # Synthetic player IDs
  @leader 9001
  @member 9002
  @outsider 9003
  @stranger 9004
  @extra_1 9005
  @extra_2 9006
  @extra_3 9007
  # @extra_4 9008 — reserved for future tests

  setup do
    # Ensure PartyServer is running (singleton GenServer with named ETS).
    case PartyServer.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Wipe all ETS state between tests for isolation.
    :ets.delete_all_objects(@table)

    :ok
  end

  # ── Helper to manually seed a party in ETS ────────────────────────────

  defp seed_party(party_id, leader, members, opts \\ []) do
    safe = Keyword.get(opts, :safe, false)

    :ets.insert(@table, {
      {:party, party_id},
      %{leader: leader, members: members, safe: safe}
    })

    for mid <- members do
      :ets.insert(@table, {{:member, mid}, party_id})
    end
  end

  defp seed_invite(target_id, from_id, party_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, 30_000)
    now = System.monotonic_time(:millisecond)

    :ets.insert(@table, {
      {:invite, target_id},
      %{from: from_id, party_id: party_id, expires_at: now + ttl}
    })
  end

  defp seed_expired_invite(target_id, from_id, party_id) do
    # Expired 5 seconds ago
    now = System.monotonic_time(:millisecond)

    :ets.insert(@table, {
      {:invite, target_id},
      %{from: from_id, party_id: party_id, expires_at: now - 5_000}
    })
  end

  # ── 1. Non-leader cannot invite ────────────────────────────────────────

  describe "non-leader invite (authority check)" do
    test "a regular member cannot invite — should return {:error, :not_leader}" do
      # Set up party: @leader is leader, @member is a regular member
      seed_party(1, @leader, [@leader, @member])

      # @member (not the leader) tries to invite @outsider
      result = PartyServer.invite(@member, @outsider)

      assert result == {:error, :not_leader},
             "Expected {:error, :not_leader} when non-leader invites, got: #{inspect(result)}"
    end
  end

  # ── 2. Expired invite acceptance ───────────────────────────────────────

  describe "expired invite acceptance" do
    test "accepting an expired invite should return {:error, :invite_expired}" do
      seed_party(1, @leader, [@leader])
      seed_expired_invite(@outsider, @leader, 1)

      result = PartyServer.accept_invite(@outsider)

      assert result == {:error, :invite_expired},
             "Expected {:error, :invite_expired} for expired invite, got: #{inspect(result)}"
    end
  end

  # ── 3. Accept invite meant for a different player ──────────────────────

  describe "cross-player invite theft" do
    test "player cannot accept an invite addressed to someone else" do
      seed_party(1, @leader, [@leader])
      # Invite is for @outsider, not @stranger
      seed_invite(@outsider, @leader, 1)

      result = PartyServer.accept_invite(@stranger)

      assert result == {:error, :no_invite},
             "Expected {:error, :no_invite} when accepting someone else's invite, got: #{inspect(result)}"
    end
  end

  # ── 4. Self-invite ─────────────────────────────────────────────────────

  describe "self-invite" do
    test "a player cannot invite themselves" do
      result = PartyServer.invite(@leader, @leader)

      assert result == {:error, :self_invite},
             "Expected {:error, :self_invite}, got: #{inspect(result)}"
    end
  end

  # ── 5. Invite a player who is already in the same party ────────────────

  describe "invite existing member" do
    test "cannot invite someone already in your party" do
      seed_party(1, @leader, [@leader, @member])

      result = PartyServer.invite(@leader, @member)

      assert result == {:error, :already_in_party},
             "Expected {:error, :already_in_party} for existing member, got: #{inspect(result)}"
    end
  end

  # ── 6. Invite when party is full ───────────────────────────────────────

  describe "full party invite" do
    test "cannot invite when party has 5 members (max)" do
      seed_party(1, @leader, [@leader, @member, @extra_1, @extra_2, @extra_3])

      result = PartyServer.invite(@leader, @outsider)

      assert result == {:error, :full},
             "Expected {:error, :full} when party is at max capacity, got: #{inspect(result)}"
    end
  end

  # ── 7. Kicked player immediate rejoin ──────────────────────────────────

  describe "kicked player rejoin cooldown" do
    test "a kicked player cannot immediately accept a new invite" do
      seed_party(1, @leader, [@leader, @member])

      # Leader kicks @member
      PartyServer.kick(@leader, @member)
      # Small delay to let the async cast process
      Process.sleep(50)

      # Verify @member is no longer in party
      assert PartyServer.get_party(@member) == :not_in_party

      # Leader sends a new invite to the kicked player
      invite_result = PartyServer.invite(@leader, @member)

      # If no cooldown exists, the invite will succeed — that itself may be
      # acceptable, but accepting it immediately should be blocked.
      # We test both: if invite is blocked, that is fine. If not, accepting should fail.
      case invite_result do
        {:error, :kick_cooldown} ->
          # Ideal: invite itself is blocked
          assert true

        :ok ->
          # Invite was allowed; accepting immediately should be blocked
          result = PartyServer.accept_invite(@member)

          assert result == {:error, :kick_cooldown},
                 "Expected {:error, :kick_cooldown} for recently kicked player, got: #{inspect(result)}"

        other ->
          flunk("Unexpected invite result for kicked player: #{inspect(other)}")
      end
    end
  end

  # ── 8. Bonus: safe_toggle authority (only leader should toggle) ────────

  describe "safe_toggle authority" do
    test "only the leader should be able to toggle safe mode" do
      seed_party(1, @leader, [@leader, @member])

      # Non-leader toggles — should not change safe mode
      PartyServer.safe_toggle(@member)
      Process.sleep(50)

      refute PartyServer.party_safe?(@member),
             "Non-leader should not be able to toggle safe mode"
    end
  end
end
