defmodule Arena.Adversarial.ChatColorSkillAdversarialTest do
  @moduledoc """
  Adversarial tests for the two recently-landed VB6 drift fixes:

    * Drift #10 — eChatColor decode + state + outbound chat-over-head color.
      VB6 refs:
        - old/server/Codigo/Protocol.bas:5548-5561 (HandleChatColor)
        - old/server/Codigo/Protocol.bas:1503      (WriteChatOverHead color)

    * Drift #11 — SubirSkill practice formula with per-level cap, hunger/
      thirst gate, quadratic probability and expert cutoff.
      VB6 refs:
        - old/server/Codigo/Modulo_UsUaRiOs.bas:1617-1670 (SubirSkill)
        - old/server/Codigo/Declares.bas:1083-1084 (EXPERT/NONEXPERT cutoffs)
        - resources/raw/Dat/Balance.dat:328        (DificultadSubirSkill = 2)

  Positive tests for the same drifts live at:
    * apps/arena/test/chat_color_handler_test.exs
    * apps/arena/test/skill_gain_formula_test.exs

  Anything here tagged `# TODO(parity)` marks a place where the current
  implementation diverges from VB6 and we expect a follow-up fix.
  """

  use ExUnit.Case, async: true

  alias AoEntities.PlayerEntity
  alias AoProtocol.Client.Decoder
  alias AoProtocol.Server.Encoder
  alias Arena.Combat
  alias Arena.Map.MapServer

  import Arena.Test.MapStateFactory

  # ===================================================================
  # ChatColor — decode (eChatColor = 421)
  # ===================================================================

  describe "Decoder.decode/1 :chat_color — RGB byte bounds" do
    test "R/G/B = 255 each decodes to the max white tuple" do
      packet = <<421::little-signed-16, 255, 255, 255>>
      assert {:ok, {:chat_color, %{r: 255, g: 255, b: 255}}, ""} = Decoder.decode(packet)
    end

    test "R/G/B = 0 each decodes to pure black" do
      packet = <<421::little-signed-16, 0, 0, 0>>
      assert {:ok, {:chat_color, %{r: 0, g: 0, b: 0}}, ""} = Decoder.decode(packet)
    end

    test "values above 255 are physically unrepresentable on the wire (Int8 is byte)" do
      # Reader.read_int8 uses unsigned-integer-8 — any byte in the stream is
      # already in 0..255. There is no way for a well-formed payload to
      # encode R/G/B > 255; we sanity-check that 255 is the decoded max.
      packet_max = <<421::little-signed-16, 255, 255, 255>>
      {:ok, {:chat_color, payload}, ""} = Decoder.decode(packet_max)
      assert payload.r <= 255 and payload.g <= 255 and payload.b <= 255
    end

    test "truncated payload (2 bytes) returns :incomplete" do
      packet = <<421::little-signed-16, 10, 20>>
      assert :incomplete = Decoder.decode(packet)
    end

    test "truncated payload (1 byte) returns :incomplete" do
      packet = <<421::little-signed-16, 10>>
      assert :incomplete = Decoder.decode(packet)
    end

    test "empty payload returns :incomplete" do
      packet = <<421::little-signed-16>>
      assert :incomplete = Decoder.decode(packet)
    end
  end

  # ===================================================================
  # ChatColor — storage (MapServer handle_cast)
  # ===================================================================

  describe "MapServer.handle_cast({:set_chat_color, ...}) — storage edge cases" do
    test "unknown char_id leaves state unchanged (missing entity)" do
      state = map_state(players: %{})

      assert {:noreply, ^state} =
               MapServer.handle_cast({:set_chat_color, 123, {10, 20, 30}}, state)
    end

    test "entity with nil :chat_color field gets the new tuple written" do
      # Construct a player entity where chat_color is explicitly nil to
      # simulate a legacy struct prior to the drift #10 field addition.
      gm = %PlayerEntity{
        char_id: 7,
        name: "LegacyGM",
        account_id: "a",
        x: 50,
        y: 50,
        gm: true,
        chat_color: nil
      }

      state = map_state(players: %{7 => gm})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:set_chat_color, 7, {100, 100, 100}}, state)

      assert Map.fetch!(new_state.players, 7).chat_color == {100, 100, 100}
    end
  end

  # ===================================================================
  # ChatColor — over-head broadcast defaults
  # ===================================================================

  describe "chat_over_head default color when entity map has no :chat_color key" do
    test "Map.get with default {255,255,255} is used when key missing" do
      # Chat.handle_chat/3 uses Map.get(entity, :chat_color, {255, 255, 255}).
      # A bare map (not a PlayerEntity struct) without the key must fall
      # back to vbWhite so upgrades do not accidentally broadcast color 0.
      entity_without_key = %{char_index: 99, x: 50, y: 50}

      color_value =
        PlayerEntity.chat_color_to_int(
          Map.get(entity_without_key, :chat_color, {255, 255, 255})
        )

      assert color_value == 255 + 255 * 256 + 255 * 65_536
    end

    test "Map.get with default is invoked for a freshly constructed map" do
      empty = %{}

      assert {255, 255, 255} = Map.get(empty, :chat_color, {255, 255, 255})
    end
  end

  # ===================================================================
  # ChatColor — chat_color_to_int/1 numeric edge cases
  # ===================================================================

  describe "PlayerEntity.chat_color_to_int/1" do
    test "{0,0,0} encodes to 0 (pure black)" do
      assert PlayerEntity.chat_color_to_int({0, 0, 0}) == 0
    end

    test "{255,255,255} encodes to 0xFFFFFF (pure white)" do
      expected = 255 + 255 * 256 + 255 * 65_536
      assert PlayerEntity.chat_color_to_int({255, 255, 255}) == expected
      assert expected == 0xFFFFFF
    end

    test "tuple of wrong arity falls through to the default white (0x00FFFFFF)" do
      assert PlayerEntity.chat_color_to_int({255, 0}) == 0x00FFFFFF
      assert PlayerEntity.chat_color_to_int({1, 2, 3, 4}) == 0x00FFFFFF
    end

    test "non-tuple inputs fall through to the default white" do
      assert PlayerEntity.chat_color_to_int(nil) == 0x00FFFFFF
      assert PlayerEntity.chat_color_to_int(:white) == 0x00FFFFFF
      assert PlayerEntity.chat_color_to_int("white") == 0x00FFFFFF
    end

    test "floats are rejected by the integer guard and fall through to default" do
      assert PlayerEntity.chat_color_to_int({1.0, 2.0, 3.0}) == 0x00FFFFFF
    end

    test "values above 255 are reduced modulo 256 (VB6 RGB clamps; we wrap)" do
      # TODO(parity): VB6's RGB() clamps components to 0..255 before packing
      # (Protocol.bas uses RGB(r, g, b); in VB6 any Byte arg is already in
      # range). Our chat_color_to_int uses rem/2, which wraps 300 → 44, so
      # out-of-range tuples encode to a different color than VB6 would.
      # The decoder can never produce such a tuple (Int8 is 0..255), but
      # internal callers (e.g. default_chat_color + buffs) could. If we
      # want strict parity, switch to min(255, max(0, x)) instead of rem/2.
      assert PlayerEntity.chat_color_to_int({300, 0, 0}) == 44
    end

    test "negative values are not wrapped — rem/2 returns the negative value" do
      # TODO(parity): Elixir `rem(-1, 256) == -1` (sign follows dividend),
      # which lets a negative component encode to a negative contribution
      # in the final Int. VB6 `RGB(-1, ...)` would raise a runtime error
      # because each arg is constrained to Byte (0..255). We should clamp
      # negative inputs to 0 (or reject the tuple) to match VB6 semantics.
      #
      # Document the current (divergent) behavior so a future fix surfaces:
      result = PlayerEntity.chat_color_to_int({-1, 0, 0})
      assert result == -1
    end
  end

  # ===================================================================
  # ChatColor — unauthorized usage (VB6 GM gate)
  # ===================================================================

  describe "unauthorized chat color change gate" do
    test "VB6 HandleChatColor silently drops non-GM writes (EsGM check)" do
      # VB6 Protocol.bas:5548-5561 — `If EsGM(UserIndex) Then .flags.ChatColor = Color`.
      # Non-GMs are silently ignored. The Elixir port upgrades this to a
      # console error ("No tienes privilegios de GM.") handled at the
      # session router layer (see chat_color_route_test.exs). There is no
      # feature-unlock / per-player flag beyond the GM check in VB6.
      #
      # The storage-layer cast has no gate of its own: it trusts that the
      # session router has already filtered non-GMs. Assert that is the
      # case — if a non-GM entity slips through to the MapServer cast,
      # VB6 parity says the write should STILL land (GM gate is at the
      # protocol handler, not the state mutation). This asserts the
      # current behavior so any accidental tightening is caught.
      non_gm = %PlayerEntity{
        char_id: 42,
        name: "Peasant",
        account_id: "a",
        x: 50,
        y: 50,
        gm: false,
        chat_color: {255, 255, 255}
      }

      state = map_state(players: %{42 => non_gm})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:set_chat_color, 42, {10, 20, 30}}, state)

      # Storage layer has no GM gate — router is responsible.
      assert Map.fetch!(new_state.players, 42).chat_color == {10, 20, 30}
    end
  end

  # ===================================================================
  # ChatColor — encoder round-trip sanity
  # ===================================================================

  describe "encoder emits the packed Int32 color" do
    test "chat_over_head color field carries chat_color_to_int/1 value" do
      color = PlayerEntity.chat_color_to_int({252, 195, 0})

      packet =
        Encoder.encode({:chat_over_head,
         %{
           message: "hi",
           char_index: 1,
           color: color,
           x: 50,
           y: 50,
           min_display_time: 2000,
           max_display_time: 5000
         }})

      # packet layout: <<id::le-16, msg_len::le-16, msg, char_index::le-16,
      #                 color::le-32, bool, x, y, min::le-16, max::le-16>>
      <<35::little-signed-16, 2::little-signed-16, "hi", 1::little-signed-16,
        encoded_color::little-signed-32, _rest::binary>> = packet

      assert encoded_color == color
    end
  end

  # ===================================================================
  # Skill gain — boundary and degenerate inputs
  # ===================================================================

  describe "Combat.roll_skill_gain/6 — skill-cap boundary" do
    test "skill at MAXSKILLPOINTS (100) never rises, regardless of level" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(50, 100, true, 100, 100, 1.0) == :no_gain
      end
    end

    test "skill at 99 can rise at a sufficiently high level (level 45)" do
      # Level 45 — maxPermitido is above 99, so the cap gate is bypassed
      # and probability kicks in. We only need one success to prove it is
      # reachable.
      result =
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(45, 99, true, 100, 100, 1.0)
        end)
        |> Stream.take(5_000)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 5} = result
    end

    test "skill at 99 but level below per-level cap still gates" do
      # Level 10 → maxPermitido = 25, so skill 99 >= 25 triggers the
      # per-level cap gate BEFORE the absolute-cap gate (order matters
      # only insofar as both return :no_gain).
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(10, 99, true, 100, 100, 1.0) == :no_gain
      end
    end
  end

  describe "Combat.roll_skill_gain/6 — hunger / thirst gate" do
    test "hunger = 0 always blocks (VB6: Stats.MinHam = 0)" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(40, 10, true, 0, 100, 1.0) == :no_gain
      end
    end

    test "thirst = 0 always blocks (VB6: Stats.MinAGU = 0)" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(40, 10, true, 100, 0, 1.0) == :no_gain
      end
    end

    test "negative hunger blocks (defensive; VB6 treats 0 as falsy)" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(40, 10, true, -5, 100, 1.0) == :no_gain
      end
    end

    test "negative thirst blocks (defensive; VB6 treats 0 as falsy)" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(40, 10, true, 100, -5, 1.0) == :no_gain
      end
    end
  end

  describe "Combat.roll_skill_gain/6 — degenerate level inputs" do
    test "level = 0 with current_skill = 0 never gains (per-level cap = 0)" do
      # max_skill_for_level(0) = 0; 0 >= 0 triggers the cap gate.
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(0, 0, true, 100, 100, 1.0) == :no_gain
      end
    end

    test "negative level is not rejected but is bounded by per-level cap" do
      # TODO(parity): VB6 assumes Stats.ELV is a positive Integer (1..49).
      # Our implementation accepts any level without validation. Depending
      # on the exact maxPermitido calc for odd negative levels the gate
      # may or may not fire. Assert the current behavior so a future
      # guard (`level < 1 -> :no_gain`) surfaces as a failing test.
      result = Combat.roll_skill_gain(-1, 99, true, 100, 100, 1.0)
      # Skill 99 + cap <= 4 for level -1 → :no_gain via cap gate.
      assert result == :no_gain
    end
  end

  describe "Combat.roll_skill_gain/6 — xp_mult edge cases" do
    test "xp_mult = 0 still rolls but bonus_exp = 0" do
      result =
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(1, 0, true, 100, 100, 0.0)
        end)
        |> Stream.take(5_000)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 0} = result
    end

    test "xp_mult very large scales bonus_exp linearly" do
      # 5 * 1.0e10 fits in integer range after trunc.
      result =
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(1, 0, true, 100, 100, 1.0e10)
        end)
        |> Stream.take(5_000)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 50_000_000_000} = result
    end

    test "xp_mult absurdly large (near float overflow) raises ArithmeticError" do
      # TODO(parity): VB6 `BonusExp = 5& * ExpMult` overflows silently
      # (Long wraps). Our port uses trunc(5 * xp_mult); multiplying by a
      # value close to the float ceiling raises. Document the divergence:
      assert_raise ArithmeticError, fn ->
        # Force a successful roll path (level 1, skill 0 → high gain chance)
        # and make sure the multiplication actually runs.
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(1, 0, true, 100, 100, 1.0e308)
        end)
        |> Stream.take(5_000)
        |> Enum.find(&match?({:gain, _}, &1))
      end
    end
  end

  describe "Combat.roll_skill_gain/6 — invalid skill key at caller layer" do
    test "roll_skill_gain does not take a skill key — level-agnostic" do
      # roll_skill_gain/6 operates on the NUMERIC skill value; it never
      # sees the skill name. The upstream call site
      # (Combat/CombatHandlers.maybe_gain_skill/4) uses
      # Map.get(entity.skills, :nonexistent, 0), which degrades
      # gracefully to 0. Assert that end-to-end invariant at the numeric
      # layer: current_skill = 0 is a valid starting point.
      result =
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(1, 0, true, 100, 100, 1.0)
        end)
        |> Stream.take(5_000)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 5} = result
    end
  end

  describe "Combat.roll_skill_gain/6 — roll independence (statistical)" do
    test "1000 independent rolls produce ~VB6 probability at level 1" do
      # VB6: Prob = Int(0.1 * Lvl^2 + 15) = 15 at level 1.
      #      Aumenta = rand(1, Prob * 2) = rand(1, 30).
      #      cutoff non-expert = 10 → gain iff Aumenta < 10 → 9/30 = 30%.
      #
      # 1000 trials with Binomial(1000, 0.30) has std-dev √(1000·0.3·0.7)
      # ≈ 14.5. A 6σ window of [213, 387] is essentially certain to hold.
      :rand.seed(:exsplus, {101, 102, 103})

      gains =
        for _ <- 1..1000, reduce: 0 do
          acc ->
            case Combat.roll_skill_gain(1, 0, false, 100, 100, 1.0) do
              {:gain, _} -> acc + 1
              :no_gain -> acc
            end
        end

      assert gains >= 200 and gains <= 400,
             "expected 1000-trial gain count in [200,400] around 300, got #{gains}"
    end

    test "rolls are independent — interleaving two seeds produces different trajectories" do
      :rand.seed(:exsplus, {1, 2, 3})

      seq_a =
        for _ <- 1..10 do
          case Combat.roll_skill_gain(1, 0, false, 100, 100, 1.0) do
            {:gain, _} -> :g
            :no_gain -> :n
          end
        end

      :rand.seed(:exsplus, {4, 5, 6})

      seq_b =
        for _ <- 1..10 do
          case Combat.roll_skill_gain(1, 0, false, 100, 100, 1.0) do
            {:gain, _} -> :g
            :no_gain -> :n
          end
        end

      refute seq_a == seq_b
    end
  end
end
