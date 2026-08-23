defmodule Arena.World.ArrivalOwnershipTest do
  @moduledoc """
  The ownership invariant: a refused arrival leaves exactly one owner, the source.

  A character is owned by exactly one MapServer. A seam crossing is a handoff, and a handoff
  that fails halfway is the worst outcome available — owned by nobody is gone, owned by two is
  worse, because both will accept commands for them.

  `W-0105` gets that by refusing the *step* rather than the transfer, using an annotation the
  topology compiler resolved and the map carries. The source holds the fact before it releases
  anybody: no cross-process call, no shared table, and no case where missing data quietly
  means yes.
  """
  use ExUnit.Case, async: false

  alias Arena.Map.Movement
  alias Arena.World.ExitAnnotations

  @source 9101
  @destination 9102

  defp exit_at(class, drawn?) do
    ExitAnnotations.synthetic(
      %{x: 88, y: 50, dest_map: @destination, dest_x: 14, dest_y: 50},
      class,
      drawn?
    )
  end

  defp state(exit_record) do
    %{
      map_id: @source,
      meta: %{tile_exit_map: %{{88, 50} => exit_record}},
      players: %{7 => entity()}
    }
  end

  defp entity(overrides \\ %{}) do
    Map.merge(%{char_index: 1, x: 87, y: 50, navigating: false}, overrides)
  end

  defp transfers(effects), do: Enum.count(effects, &match?({:transfer, _, _, _, _, _}, &1))
  defp owners(state, char_id), do: if(Map.has_key?(state.players, char_id), do: 1, else: 0)

  defp in_a_temp_dir(work) do
    dir = Path.join(System.tmp_dir!(), "arrival-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:arena, :exit_annotations_dir)
    Application.put_env(:arena, :exit_annotations_dir, dir)

    try do
      work.(dir)
    after
      if previous do
        Application.put_env(:arena, :exit_annotations_dir, previous)
      else
        Application.delete_env(:arena, :exit_annotations_dir)
      end

      File.rm_rf!(dir)
    end
  end

  describe "a refused arrival begins no handoff" do
    test "solid ground: no transfer, and the source is still the only owner" do
      state = state(exit_at(:solid, true))

      assert Movement.arrival_verdict(state, entity(), 88, 50) == {:error, :arrival_solid}
      {returned, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 88, 50)

      refute transferring?
      assert transfers(effects) == 0, "no handoff may begin"
      assert owners(returned, 7) == 1, "exactly one owner, and it is the source"
      assert returned.players[7].x == 87, "position untouched"
      assert returned.players[7].y == 50
    end

    test "an undrawn tile: no transfer, whatever its blocked byte says" do
      state = state(exit_at(:walkable, false))

      assert Movement.arrival_verdict(state, entity(), 88, 50) == {:error, :arrival_void}
      {returned, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 88, 50)

      refute transferring?
      assert transfers(effects) == 0
      assert owners(returned, 7) == 1
    end

    test "water refuses a walker and carries a boat" do
      state = state(exit_at(:water, true))

      assert Movement.arrival_verdict(state, entity(), 88, 50) == {:error, :arrival_requires_boat}
      {_, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 88, 50)
      refute transferring?
      assert transfers(effects) == 0

      sailor = entity(%{navigating: true})
      assert Movement.arrival_verdict(state, sailor, 88, 50) == :ok
      {_, transferring?, effects} = Movement.check_tile_exit(state, 7, sailor, 88, 50)
      assert transferring?
      assert transfers(effects) == 1
    end
  end

  describe "missing or mismatched metadata fails closed" do
    test "an exit with no annotation at all is refused" do
      # The first version of this rule allowed the transfer whenever data was missing, which
      # made "the source validates the destination" false in exactly the case where it
      # mattered. 1,196 exits in this corpus name a map that does not exist.
      state = state(%{x: 88, y: 50, dest_map: @destination, dest_x: 14, dest_y: 50})

      assert Movement.arrival_verdict(state, entity(), 88, 50) == {:error, :arrival_unknown}
      {returned, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 88, 50)

      refute transferring?
      assert transfers(effects) == 0
      assert owners(returned, 7) == 1
    end

    test "an annotation from a different world version is not merged" do
      exits = [%{x: 88, y: 50, dest_map: @destination, dest_x: 14, dest_y: 50}]

      in_a_temp_dir(fn dir ->
        File.write!(
          Path.join(dir, "map-#{@source}.txt"),
          "# version older-world\n88 50 #{@destination} 14 50 walkable drawn\n"
        )

        annotated = ExitAnnotations.annotate(exits, @source, "this-world")
        refute Map.has_key?(hd(annotated), :arrival), "a stale annotation must not be trusted"

        assert Movement.arrival_verdict(state(hd(annotated)), entity(), 88, 50) ==
                 {:error, :arrival_unknown}

        # With the version it was compiled for, the same file is used.
        annotated = ExitAnnotations.annotate(exits, @source, "older-world")
        assert hd(annotated).arrival.class == :walkable
        assert Movement.arrival_verdict(state(hd(annotated)), entity(), 88, 50) == :ok
      end)
    end

    test "an annotation naming a different destination than the map is not merged" do
      # The file and the map data disagreeing about the world is exactly when guessing is
      # worst, so neither is believed.
      exits = [%{x: 88, y: 50, dest_map: @destination, dest_x: 14, dest_y: 50}]

      in_a_temp_dir(fn dir ->
        File.write!(
          Path.join(dir, "map-#{@source}.txt"),
          "# version w\n88 50 #{@destination} 20 20 walkable drawn\n"
        )

        annotated = ExitAnnotations.annotate(exits, @source, "w")
        refute Map.has_key?(hd(annotated), :arrival)
      end)
    end

    test "a missing annotation file leaves every exit unannotated" do
      in_a_temp_dir(fn _dir ->
        exits = [%{x: 88, y: 50, dest_map: @destination, dest_x: 14, dest_y: 50}]
        annotated = ExitAnnotations.annotate(exits, 424_242, "w")
        refute Map.has_key?(hd(annotated), :arrival)
      end)
    end

    test "an unrecognised class is treated as solid, not as open ground" do
      in_a_temp_dir(fn dir ->
        File.write!(
          Path.join(dir, "map-#{@source}.txt"),
          "# version w\n88 50 #{@destination} 14 50 lava drawn\n"
        )

        exits = [%{x: 88, y: 50, dest_map: @destination, dest_x: 14, dest_y: 50}]
        annotated = ExitAnnotations.annotate(exits, @source, "w")
        assert hd(annotated).arrival.class == :solid
      end)
    end
  end

  describe "a valid arrival hands off exactly once" do
    test "walking across emits one transfer naming the annotated destination" do
      state = state(exit_at(:walkable, true))

      assert Movement.arrival_verdict(state, entity(), 88, 50) == :ok
      {_, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 88, 50)

      assert transferring?
      assert transfers(effects) == 1

      [{:transfer, char_id, dest_map, dest_x, dest_y, _}] =
        Enum.filter(effects, &match?({:transfer, _, _, _, _, _}, &1))

      assert {char_id, dest_map, dest_x, dest_y} == {7, @destination, 14, 50}
    end

    test "a boat beaching on dry ground still works" do
      # 865 boundary pairs in the corpus can do this and 856 of them carry an exit. Refusing
      # it here would be a gameplay change smuggled into a defect fix.
      state = state(exit_at(:walkable, true))
      sailor = entity(%{navigating: true})

      assert Movement.arrival_verdict(state, sailor, 88, 50) == :ok
      {_, _, effects} = Movement.check_tile_exit(state, 7, sailor, 88, 50)
      assert transfers(effects) == 1
    end

    test "the decision is deterministic, which is not the same as deduplicated" do
      # Named for what it proves. Three calls produce three transfer effects, one per call:
      # the classification is a pure function of the exit and the entity, so repeating the
      # question never changes the answer. That is worth pinning, and it is *not* idempotence
      # -- nothing here would stop a duplicated movement message from starting two handoffs.
      # Deduplication needs a transfer id and a prepare/commit state machine, and that is
      # W-0096's to build and to prove.
      state = state(exit_at(:walkable, true))

      results =
        for _ <- 1..3 do
          {returned, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 88, 50)
          assert transferring?
          assert owners(returned, 7) == 1, "the source has not removed anybody yet"
          transfers(effects)
        end

      assert results == [1, 1, 1], "one transfer per decision, three decisions"
    end
  end

  describe "what the rule does not touch" do
    test "a tile with no exit is not an arrival question" do
      state = state(exit_at(:solid, true))
      assert Movement.arrival_verdict(state, entity(), 50, 50) == :ok

      {_, transferring?, effects} = Movement.check_tile_exit(state, 7, entity(), 50, 50)
      refute transferring?
      assert effects == []
    end
  end

  describe "the world identity" do
    test "the annotations claim the same hash the pack does" do
      # The check that matters, and the one version.txt cannot make on its own: the artefact's
      # claim compared against the pack this server actually loaded.
      expected = ExitAnnotations.expected_version()
      claimed = ExitAnnotations.claimed_version()

      assert is_binary(expected), "the server must know which world it serves"
      assert claimed == expected, "annotations describe #{claimed}, pack is #{expected}"
      assert :ok == ExitAnnotations.verify!()

      # And it is the identity the rest of the system already uses: the pack's filename.
      assert String.length(expected) == 16
    end

    test "a matching configuration pin is accepted and changes nothing" do
      # The pin is an assertion about the pack. When it agrees, it is redundant, and the pack
      # is still what everything is compared against.
      actual = ExitAnnotations.expected_version()
      previous = Application.get_env(:arena, :map_pack_hash)
      Application.put_env(:arena, :map_pack_hash, actual)

      try do
        assert ExitAnnotations.configured_pin() == actual
        assert ExitAnnotations.expected_version() == actual
        assert :ok == ExitAnnotations.verify!()
      after
        if previous do
          Application.put_env(:arena, :map_pack_hash, previous)
        else
          Application.delete_env(:arena, :map_pack_hash)
        end
      end
    end

    test "a mismatching configuration pin fails the boot and never wins" do
      # The hole this closes: if configuration could answer "which world is this", a stale pin
      # and stale annotations would validate each other while both described a world nobody is
      # serving.
      actual = ExitAnnotations.expected_version()
      previous = Application.get_env(:arena, :map_pack_hash)
      Application.put_env(:arena, :map_pack_hash, "0000000000000000")

      try do
        assert ExitAnnotations.expected_version() == actual,
               "the pack, not the pin, is the source of truth"

        error =
          assert_raise RuntimeError, ~r/Configuration pins a different world/, fn ->
            ExitAnnotations.verify!()
          end

        # Both values are named, because "mismatch" alone sends nobody anywhere.
        assert error.message =~ actual
        assert error.message =~ "0000000000000000"
      after
        if previous do
          Application.put_env(:arena, :map_pack_hash, previous)
        else
          Application.delete_env(:arena, :map_pack_hash)
        end
      end
    end

    test "a version mismatch is a boot failure, not a warning" do
      in_a_temp_dir(fn dir ->
        File.write!(Path.join(dir, "version.txt"), "some-other-world\n")

        assert_raise RuntimeError, ~r/different world than this server loaded/, fn ->
          ExitAnnotations.verify!()
        end
      end)
    end

    test "annotations with no version.txt are a boot failure" do
      in_a_temp_dir(fn _dir ->
        assert_raise RuntimeError, ~r/do not say which world they describe/, fn ->
          ExitAnnotations.verify!()
        end
      end)
    end

    test "a missing annotation directory is a boot failure" do
      previous = Application.get_env(:arena, :exit_annotations_dir)
      Application.put_env(:arena, :exit_annotations_dir, "/nonexistent/arrival")

      try do
        assert_raise RuntimeError, ~r/Exit annotations are missing/, fn ->
          ExitAnnotations.verify!()
        end
      after
        if previous do
          Application.put_env(:arena, :exit_annotations_dir, previous)
        else
          Application.delete_env(:arena, :exit_annotations_dir)
        end
      end
    end
  end

  describe "the compiled annotations for the real corpus" do
    test "the acceptance square's exits are annotated, and its south seam is walkable" do
      # A build artefact, so this checks it only when it is present.
      path = Path.join(ExitAnnotations.directory(), "map-330.txt")

      if File.exists?(path) do
        [_, version] = Regex.run(~r/^#\s*version\s+(\S+)/m, File.read!(path))
        annotations = ExitAnnotations.load(330, version)

        assert map_size(annotations) > 0

        # Walking south off 330's core edge crosses band (14,91) into 274 (14,11), which is
        # the pinned route in `walking_paths.txt`.
        assert %{class: :walkable, drawn?: true, dest_map: 274, dest_x: 14, dest_y: 11} =
                 annotations[{14, 91}]
      end
    end
  end
end
