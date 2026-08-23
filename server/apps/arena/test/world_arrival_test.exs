defmodule Arena.World.ArrivalTest do
  @moduledoc """
  The arrival rule, and the corpus-wide gate it has to pass.

  `test/fixtures/arrival_cases.txt` is generated from the real map pack by the topology
  compiler (`ao-topology <pack> --arrivals <path>`) and states the rule's *inputs* — the
  destination tile's class, whether the map draws it, and how the character travels — beside
  the verdict this module must reach. Every rejection in the corpus is listed in full and the
  acceptances are sampled, so the gate catches both a defect slipping through and the rule
  over-rejecting something that works today.
  """
  use ExUnit.Case, async: true

  alias Arena.World.Arrival

  @cases Path.join([__DIR__, "fixtures", "arrival_cases.txt"])

  # Mapped explicitly, never `to_existing_atom`. An atom exists only once some loaded module
  # mentions it, so parsing external data that way passes or fails depending on which test ran
  # first -- the wire contract test did exactly that, passing alone and failing in the suite.
  defp class_named("walkable"), do: :walkable
  defp class_named("solid"), do: :solid
  defp class_named("water"), do: :water

  defp fixture do
    @cases
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      # Read by keyword rather than by position: a column added to the generator would
      # otherwise shift every field silently and the gate would still pass.
      fields = String.split(line, ~r/\s+/)

      after_word = fn word ->
        case Enum.find_index(fields, &(&1 == word)) do
          nil -> nil
          at -> Enum.at(fields, at + 1)
        end
      end

      [_, verdict] = String.split(line, "-> ", parts: 2)

      %{
        line: line,
        class: class_named(after_word.("arrival")),
        drawn?: after_word.("drawn") == "yes",
        locomotion: after_word.("locomotion"),
        reachable?: after_word.("reachable") == "yes",
        verdict: String.trim(verdict)
      }
    end)
  end

  describe "the rule itself" do
    test "solid is refused for everyone" do
      assert Arrival.validate(:solid, true, false) == {:error, :arrival_solid}
      assert Arrival.validate(:solid, true, true) == {:error, :arrival_solid}
    end

    test "an undrawn tile is refused for everyone, whatever its blocked byte says" do
      # The bounding rectangle makes 2,444 void tiles read as walkable floor. A tile with no
      # ground is not a place, and the blocked layer cannot say so on its own.
      assert Arrival.validate(:walkable, false, false) == {:error, :arrival_void}
      assert Arrival.validate(:walkable, false, true) == {:error, :arrival_void}
      assert Arrival.validate(:water, false, true) == {:error, :arrival_void}
      assert Arrival.validate(:solid, false, false) == {:error, :arrival_void}
    end

    test "water needs a boat" do
      assert Arrival.validate(:water, true, false) == {:error, :arrival_requires_boat}
      assert Arrival.validate(:water, true, true) == :ok
    end

    test "walkable ground accepts either, which keeps boat beaching working" do
      # 856 boundaries in the corpus land a navigating character on dry ground. Whether a
      # ship should run aground is a content decision, and refusing it here would smuggle
      # that decision into a defect fix.
      assert Arrival.validate(:walkable, true, false) == :ok
      assert Arrival.validate(:walkable, true, true) == :ok
    end

    test "verdicts carry stable typed reasons rather than prose" do
      for reason <- [:arrival_solid, :arrival_void, :arrival_requires_boat] do
        assert is_binary(Arrival.reason_name(reason))
      end

      refute Arrival.allowed?({:error, :arrival_solid})
      assert Arrival.allowed?(:ok)
    end

    test "a raw tile value reaches the same verdict as its class" do
      assert Arrival.validate_value(0, true, false) == :ok
      assert Arrival.validate_value(1, true, false) == {:error, :arrival_solid}
      assert Arrival.validate_value(2, true, false) == {:error, :arrival_requires_boat}
      assert Arrival.validate_value(2, true, true) == :ok
    end
  end

  describe "the corpus gate" do
    test "the fixture covers every measured defect and a sample of what works" do
      cases = fixture()
      by_verdict = Enum.frequencies_by(cases, & &1.verdict)

      assert by_verdict["reject solid"] == 2877
      assert by_verdict["reject void"] == 48
      assert by_verdict["reject water-on-foot"] == 4
      assert by_verdict["accept walking"] > 0
      assert by_verdict["accept sailing"] > 0
      assert by_verdict["accept beaching"] > 0
    end

    test "the reachable defects are the 169, 24 and 4 the compiler reported" do
      # Reachability is recorded so the fix's impact is honest: an unreachable bad arrival is
      # still invalid, it just cannot bite until somebody clears the way out. One of the 169
      # solid arrivals is also undrawn, so it is counted as void.
      reachable = fixture() |> Enum.filter(& &1.reachable?) |> Enum.frequencies_by(& &1.verdict)

      assert reachable["reject solid"] == 168
      assert reachable["reject void"] == 24
      assert reachable["reject water-on-foot"] == 4
    end

    test "every case in the corpus reaches the verdict the fixture states" do
      for kase <- fixture() do
        navigating? = kase.locomotion == "boat"
        verdict = Arrival.validate(kase.class, kase.drawn?, navigating?)

        expected =
          case kase.verdict do
            "reject solid" -> {:error, :arrival_solid}
            "reject void" -> {:error, :arrival_void}
            "reject water-on-foot" -> {:error, :arrival_requires_boat}
            "accept walking" -> :ok
            "accept sailing" -> :ok
            "accept beaching" -> :ok
          end

        assert verdict == expected, """
        #{kase.line}
        expected #{inspect(expected)}, got #{inspect(verdict)}
        """
      end
    end

    test "an unreachable case is judged on its destination, not on being unreachable" do
      # `locomotion any` means the way out is solid so nobody arrives today. The rule still
      # refuses, because a rule that only covered reachable arrivals would pass this gate and
      # admit the rest the moment a wall moved.
      unreachable = fixture() |> Enum.reject(& &1.reachable?)
      assert unreachable != []

      for kase <- unreachable do
        assert kase.locomotion == "any"
        refute Arrival.allowed?(Arrival.validate(kase.class, kase.drawn?, false))
        refute Arrival.allowed?(Arrival.validate(kase.class, kase.drawn?, true))
      end
    end
  end
end
