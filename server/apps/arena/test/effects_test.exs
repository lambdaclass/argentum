defmodule Arena.Map.EffectsTest do
  use ExUnit.Case, async: true

  alias Arena.Map.Effects

  import Arena.Test.MapStateFactory

  describe "run/2" do
    test "empty list is a no-op" do
      assert :ok = Effects.run(%{sessions: %{}}, [])
    end

    test ":send routes the envelope to the session pid via Egress" do
      state = %{sessions: %{42 => self()}}
      assert :ok = Effects.run(state, [Effects.send(42, "hello")])
      assert_receive {:egress, %{class: :critical, payload: "hello"}}
    end

    test ":send to a missing session is silently dropped" do
      state = %{sessions: %{}}
      assert :ok = Effects.run(state, [Effects.send(999, "x")])
      refute_receive _, 50
    end

    test "preserves order across multiple :send effects to the same session" do
      state = %{sessions: %{1 => self()}}

      effects = [
        Effects.send(1, "aa"),
        Effects.send(1, "bb"),
        Effects.send(1, "cc")
      ]

      assert :ok = Effects.run(state, effects)
      assert_receive {:egress, %{payload: "aa"}}
      assert_receive {:egress, %{payload: "bb"}}
      assert_receive {:egress, %{payload: "cc"}}
    end

    test "unknown effect raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Effects.run(%{sessions: %{}}, [{:bogus, 1, 2}])
      end
    end
  end

  describe "send/3 envelope construction" do
    test "defaults class via AoProtocol.Classify.class_for/1 (first 2 bytes as packet ID)" do
      # console_msg is :critical by classifier
      console_id = AoProtocol.PacketIds.Server.console_msg()
      packet = <<console_id::little-signed-integer-16, "hi"::binary>>

      {:send, _, env} = Effects.send(:p, packet)
      assert env.class == :critical
      assert env.coalesce_key == nil
    end

    test "defaults to :coalesce class with packet id as key for stat-stream packets" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:send, _, env} = Effects.send(:p, packet)
      assert env.class == :coalesce
      assert env.coalesce_key == hp_id
    end

    test "class: override beats classifier default" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:send, _, env} = Effects.send(:p, packet, class: :critical)
      assert env.class == :critical
    end

    test "coalesce_key: override beats classifier default" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:send, _, env} = Effects.send(:p, packet, coalesce_key: {:hp, :p})
      assert env.class == :coalesce
      assert env.coalesce_key == {:hp, :p}
    end
  end

  describe "run/2 :broadcast_visible_all" do
    # End-to-end check: a broadcast effect flows through Visibility →
    # AoSession.Egress.enqueue → mailbox of every session inside AoI,
    # carrying the envelope built by the constructor.
    test "fans the envelope to every session whose AoI covers (x, y)" do
      origin = self()

      peer_pid =
        spawn_link(fn ->
          receive do
            {:egress, env} -> Kernel.send(origin, {:peer_received, env})
          end
        end)

      origin_x = 50
      origin_y = 50

      players = %{
        meditator: %{x: origin_x, y: origin_y, gm: false},
        peer: %{x: origin_x + 1, y: origin_y, gm: false}
      }

      state =
        map_state(
          players: players,
          sessions: %{meditator: origin, peer: peer_pid},
          visibility_mode: :global
        )

      # Real packet so the classifier picks :lossy (create_fx).
      fx_id = AoProtocol.PacketIds.Server.create_fx()
      payload = <<fx_id::little-signed-integer-16, 1, 0, 4, 0, 0, 0>>

      assert :ok =
               Effects.run(state, [Effects.broadcast_visible_all(origin_x, origin_y, payload)])

      assert_receive {:egress, %{class: :lossy, payload: ^payload}}
      assert_receive {:peer_received, %{class: :lossy, payload: ^payload}}
    end
  end

  describe "send/3 constructor robustness — adversarial" do
    test "empty binary packet falls back to :critical with nil coalesce_key" do
      # Less than 2 bytes for packet-ID peek — must NOT crash; runner picks safe default.
      {:send, _, env} = Effects.send(:p, "")
      assert env.class == :critical
      assert env.coalesce_key == nil
      assert env.payload == ""
    end

    test "single-byte binary packet falls back to :critical (less than 2 bytes for ID peek)" do
      {:send, _, env} = Effects.send(:p, <<42>>)
      assert env.class == :critical
      assert env.coalesce_key == nil
      assert env.payload == <<42>>
    end

    test "class: :lossy override on an unknown packet ID still produces :lossy" do
      # Use a packet id (0xFFFF) that is not in any classify set. Default would be :critical.
      packet = <<0xFFFF::little-signed-integer-16, 1, 2, 3>>
      {:send, _, env} = Effects.send(:p, packet, class: :lossy)
      assert env.class == :lossy
    end

    test "raises on non-binary packet (atom)" do
      assert_raise FunctionClauseError, fn ->
        Effects.send(:p, :not_a_binary)
      end
    end

    test "raises on non-binary packet (iodata list)" do
      # iodata is allowed at the typespec level for Effect.t() (declared as iodata())
      # but the constructor is intentionally tighter: it needs a flat binary so the
      # 16-bit packet-ID peek works. Iodata lists must be flattened by the caller.
      assert_raise FunctionClauseError, fn ->
        Effects.send(:p, [<<1>>, <<2>>])
      end
    end
  end

  describe "broadcast_visible/4 + broadcast_visible_all/4 constructor opts" do
    test "broadcast_visible/4 honours class: override (not just send/3)" do
      # update_hp default is :coalesce — override to :critical and verify the env flips.
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:broadcast_visible, _x, _y, env} =
        Effects.broadcast_visible(10, 10, packet, class: :critical)

      assert env.class == :critical
    end

    test "broadcast_visible_all/4 honours class: override" do
      console_id = AoProtocol.PacketIds.Server.console_msg()
      packet = <<console_id::little-signed-integer-16, "x"::binary>>

      {:broadcast_visible_all, _x, _y, env} =
        Effects.broadcast_visible_all(10, 10, packet, class: :lossy)

      assert env.class == :lossy
    end

    test "broadcast_visible/4 honours coalesce_key: override" do
      hp_id = AoProtocol.PacketIds.Server.update_hp()
      packet = <<hp_id::little-signed-integer-16, 0, 0, 0, 0>>

      {:broadcast_visible, _x, _y, env} =
        Effects.broadcast_visible(10, 10, packet, coalesce_key: {:hp_aoe, 7})

      assert env.class == :coalesce
      assert env.coalesce_key == {:hp_aoe, 7}
    end
  end

  describe "run/2 stress and failure modes" do
    test "executes a mixed-kind list (:send + :broadcast_visible + :broadcast_visible_all + :broadcast_character_change) in declaration order" do
      origin = self()

      ox = 50
      oy = 50

      entity = %{
        char_id: :actor,
        char_index: 7,
        x: ox,
        y: oy,
        heading: :south,
        body_id: 1,
        head_id: 2,
        dead: false,
        equipment: %{weapon: 0, shield: 0, helmet: 0},
        gm: false
      }

      players = %{
        actor: entity,
        peer: %{x: ox + 1, y: oy, gm: false}
      }

      state =
        map_state(
          players: players,
          sessions: %{actor: origin},
          visibility_mode: :global
        )

      # Real packets so we can match concrete envelope payloads back in the mailbox.
      console_id = AoProtocol.PacketIds.Server.console_msg()
      send_payload = <<console_id::little-signed-integer-16, "first"::binary>>

      fx_id = AoProtocol.PacketIds.Server.create_fx()
      bv_payload = <<fx_id::little-signed-integer-16, 0, 1, 0, 4, 0, 0, 0>>
      bva_payload = <<fx_id::little-signed-integer-16, 1, 1, 0, 4, 0, 0, 0>>

      cc_payload =
        AoProtocol.Server.Encoder.encode(Arena.Map.Helpers.character_change_packet(entity))

      effects = [
        Effects.send(:actor, send_payload),
        Effects.broadcast_visible(ox, oy, bv_payload),
        Effects.broadcast_visible_all(ox, oy, bva_payload),
        Effects.broadcast_character_change(entity)
      ]

      assert :ok = Effects.run(state, effects)

      # All four effect kinds touch `self()` because the dispatcher passes
      # `exclude_id: nil` for both :broadcast_visible and :broadcast_visible_all
      # (the "exclude origin" semantic is the call site's responsibility, per
      # the Effect moduledoc — the runner just fans out via Visibility).
      # Mailbox order must match declaration order.
      assert_receive {:egress, %{payload: msg1}}
      assert msg1 == send_payload, "first envelope must be the :send payload"

      assert_receive {:egress, %{payload: msg2}}
      assert msg2 == bv_payload, "second envelope must be :broadcast_visible payload"

      assert_receive {:egress, %{payload: msg3}}
      assert msg3 == bva_payload, "third envelope must be :broadcast_visible_all payload"

      assert_receive {:egress, %{payload: msg4}}
      assert msg4 == cc_payload, "fourth envelope must be :broadcast_character_change payload"
    end

    test "tolerates a dead session pid (no crash, returns :ok)" do
      dead_pid = spawn(fn -> :ok end)
      # Wait for the spawned process to exit deterministically.
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}, 200
      refute Process.alive?(dead_pid)

      state = %{sessions: %{:p => dead_pid}}

      # Should not raise even though the pid is dead — Kernel.send/2 to a dead
      # pid is a no-op at the BEAM level.
      assert :ok = Effects.run(state, [Effects.send(:p, "irrelevant")])
    end

    test "no-op when state has empty sessions and effect targets a missing char_id" do
      state = %{sessions: %{}}
      assert :ok = Effects.run(state, [Effects.send(:nonexistent, "x")])
      refute_receive _, 50
    end

    test "unknown effect mid-list raises ArgumentError AFTER prior effects already ran" do
      state = %{sessions: %{:p => self()}}

      effects = [
        Effects.send(:p, "before-bad"),
        {:bogus_effect, :data},
        Effects.send(:p, "after-bad")
      ]

      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        Effects.run(state, effects)
      end

      # Prior effect side effect (the :send) MUST have fired before the raise.
      assert_receive {:egress, %{payload: "before-bad"}}
      # The trailing effect after the bad tuple must NOT have executed.
      refute_receive {:egress, %{payload: "after-bad"}}, 50
    end
  end

  describe "run_handler/2 adapter" do
    test "returns the post-handler state, not the pre-handler state" do
      pre = %{sessions: %{}, players: %{}, marker: :before}

      handler = fn s ->
        # Verifies the closure receives the caller's state and is free to
        # transform it. The runner must thread the new state out, not echo
        # back the input.
        new_state = Map.put(s, :marker, :after)
        {:ok, new_state, []}
      end

      assert {:noreply, post} = Effects.run_handler(pre, handler)
      assert post.marker == :after
    end

    test "runs the produced effects against the post-handler state" do
      # Handler updates `sessions` so the runner has a route. If the runner
      # used the pre-handler state (empty sessions) the :send would silently
      # drop and we'd never receive the message.
      origin = self()
      pre = %{sessions: %{}}

      handler = fn s ->
        new_state = %{s | sessions: Map.put(s.sessions, :p, origin)}
        {:ok, new_state, [Effects.send(:p, "hello-from-post")]}
      end

      assert {:noreply, post} = Effects.run_handler(pre, handler)
      assert post.sessions[:p] == origin
      assert_receive {:egress, %{payload: "hello-from-post"}}
    end
  end

  describe "run/2 :transfer" do
    test "sends the bare {:transfer, dest_map, dest_x, dest_y, entity} tuple to the session pid" do
      entity = %{char_index: 7, x: 10, y: 20}
      state = %{sessions: %{:p => self()}}

      assert :ok =
               Effects.run(state, [Effects.transfer(:p, 42, 50, 60, entity)])

      # The runner must strip the char_id and send the shape the session
      # handlers (WsHandler/ClientHandler) actually pattern-match.
      assert_receive {:transfer, 42, 50, 60, ^entity}
    end

    test "is silently dropped when the char_id has no session" do
      state = %{sessions: %{}}
      entity = %{char_index: 7}

      assert :ok =
               Effects.run(state, [Effects.transfer(:missing, 1, 2, 3, entity)])

      refute_receive {:transfer, _, _, _, _}, 50
    end

    test "constructor returns the tagged tuple unchanged" do
      entity = %{char_index: 1}
      assert {:transfer, :p, 5, 6, 7, ^entity} = Effects.transfer(:p, 5, 6, 7, entity)
    end
  end

  describe "run/2 :broadcast_character_change" do
    # End-to-end check: the character_change effect lands on every nearby
    # session as a critical Egress envelope carrying the encoded
    # character_change packet. This guards the path that handle_resucitate
    # (and other producers) rely on after slice 4.
    test "fans a critical character_change envelope to every visible session" do
      origin = self()

      peer_pid =
        spawn_link(fn ->
          receive do
            {:egress, env} -> Kernel.send(origin, {:peer_received, env})
          end
        end)

      ox = 50
      oy = 50

      entity = %{
        char_index: 7,
        x: ox,
        y: oy,
        heading: :south,
        body_id: 1,
        head_id: 2,
        dead: false,
        equipment: %{weapon: 0, shield: 0, helmet: 0},
        gm: false
      }

      players = %{
        actor: entity,
        peer: %{x: ox + 1, y: oy, gm: false}
      }

      state =
        map_state(
          players: players,
          sessions: %{actor: origin, peer: peer_pid},
          visibility_mode: :global
        )

      expected_payload =
        AoProtocol.Server.Encoder.encode(Arena.Map.Helpers.character_change_packet(entity))

      assert :ok =
               Effects.run(state, [Effects.broadcast_character_change(entity)])

      assert_receive {:egress, %{class: :critical, payload: ^expected_payload}}
      assert_receive {:peer_received, %{class: :critical, payload: ^expected_payload}}
    end
  end
end
