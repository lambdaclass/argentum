defmodule Arena.Map.SocialForumE2ETest do
  @moduledoc """
  End-to-end tests for the Social forum-open flow. Pins the Social
  effects-contract migration (Sub F: forum_open).

  `handle_forum_open/3` is unusual: the wire packet (`:show_forum_form`)
  goes through the effects pipeline as `Effects.send/2` and arrives in
  the test pid mailbox as an `{:egress, %AoSession.Outbound{...}}`
  envelope, but the handler also dispatches a session-state message
  `{:set_viewing_forum, forum_id}` directly to the session pid via the
  legacy shim. That message is intentionally NOT migrated — no other
  handler emits a session-state-only signal, so we keep the direct send
  rather than introduce a one-off effect kind. This test pins both
  shapes so any future refactor breaks it loudly.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.Social
  alias Arena.Data.GameData
  alias Arena.Forum
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Forum.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    drain()
    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp make_player(overrides \\ %{}) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      char_index: 1,
      map_id: 1,
      hp: 100,
      max_hp: 100,
      gold: 0,
      level: 25,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      skills: %{},
      inventory: List.duplicate(nil, 24),
      faction: :none,
      dead: false
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp state_with(player, opts \\ []) do
    map_state(
      players: %{player.char_id => player},
      sessions: Keyword.get(opts, :sessions, %{player.char_id => self()}),
      occupancy: Keyword.get(opts, :occupancy, %{})
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # Social.handle_forum_open/3 (called via Effects.run_handler from
  # NpcInteraction.handle_double_click on a forum object)
  # ════════════════════════════════════════════════════════════════════════

  describe "handle_forum_open" do
    test "alive player: returns {:ok, state, [show_forum_form effect]} and sends session-state msg" do
      state = state_with(make_player())
      forum_id = 1

      assert {:ok, ^state, effects} = Social.handle_forum_open(state, :player, forum_id)

      # Effect list contains exactly one :send carrying the show_forum_form
      # packet (id 202). State must be unchanged because forum-open is
      # purely a read.
      show_id = AoProtocol.PacketIds.Server.show_forum_form()

      assert [{:send, :player, %{payload: <<^show_id::little-signed-integer-16, _::binary>>}}] =
               effects

      # The legacy session-state shim still fires directly (not via effects).
      assert_receive {:set_viewing_forum, ^forum_id}
    end

    test "running the effect produces an Egress envelope, never a {:send_raw, _}" do
      state = state_with(make_player())
      forum_id = 7
      show_id = AoProtocol.PacketIds.Server.show_forum_form()

      assert {:ok, ^state, effects} = Social.handle_forum_open(state, :player, forum_id)

      :ok = Arena.Map.Effects.run(state, effects)

      assert_receive {:egress, %{payload: <<^show_id::little-signed-integer-16, _::binary>>}}
      # Both arrive in this test pid (since session and test pid are the same)
      assert_receive {:set_viewing_forum, ^forum_id}
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: empty effects, state unchanged, no envelopes, no session msg" do
      state = state_with(make_player())
      empty_state = %{state | players: %{}}

      assert {:ok, ^empty_state, []} = Social.handle_forum_open(empty_state, :ghost, 1)

      refute_receive {:set_viewing_forum, _}, 50
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "stale session pid: effect dispatches without raising, no session-state msg either" do
      # Player exists but their session entry is missing — the legacy shim
      # silently drops the {:set_viewing_forum, _} message and the :send
      # effect's Helpers.send_outbound silently drops too.
      player = make_player()
      state = state_with(player, sessions: %{})

      assert {:ok, ^state, effects} = Social.handle_forum_open(state, :player, 3)

      :ok = Arena.Map.Effects.run(state, effects)

      refute_receive {:set_viewing_forum, _}, 50
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
