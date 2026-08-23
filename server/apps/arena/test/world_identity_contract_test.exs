defmodule Arena.World.IdentityContractTest do
  @moduledoc """
  The server's half of the identity and authority contract.

  Reads the same hand-authored fixture `ao_core::identity` reads. These are the rules a router
  applies before letting anything act on an entity, so a divergence between the two sides is a
  divergence about who may move a player.
  """
  use ExUnit.Case, async: true

  alias Arena.World.Identity

  @contract Path.join([
              __DIR__,
              "..",
              "..",
              "..",
              "..",
              "client-rs",
              "crates",
              "ao-core",
              "fixtures",
              "identity_contract.txt"
            ])

  defp cases do
    @contract
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      [body, expected] = String.split(line, "->", parts: 2)
      {line, String.split(String.trim(body), ~r/\s+/), String.split(String.trim(expected), ~r/\s+/)}
    end)
  end

  test "the contract covers every rule and is worth checking" do
    kinds = cases() |> Enum.map(fn {_, [kind | _], _} -> kind end) |> Enum.uniq() |> Enum.sort()
    assert kinds == ["advance", "execute", "instances", "placements", "seamless"]
    assert length(cases()) >= 24
  end

  test "elixir satisfies every case in the identity contract" do
    for {line, body, expected} <- cases() do
      case body do
        ["execute", "owner", entity, region, epoch, "command", command_entity, command_epoch,
         "reach", reach] ->
          owner = %{
            entity: String.to_integer(entity),
            region: String.to_integer(region),
            epoch: String.to_integer(epoch)
          }

          command = %{
            entity: String.to_integer(command_entity),
            epoch: String.to_integer(command_epoch)
          }

          # Mapped explicitly rather than by `to_existing_atom`, so the test does not depend
          # on whether an atom happens to have been interned elsewhere.
          reach =
            case reach do
              "authoritative" -> :authoritative
              "observed" -> :observed
            end

          got = Identity.may_execute(command, owner, reach)

          want =
            case expected do
              ["ok"] -> :ok
              ["not-owner"] -> {:error, :not_owner}
              ["stale-epoch"] -> {:error, :stale_epoch}
              ["read-only"] -> {:error, :read_only}
            end

          assert got == want, "#{line} gave #{inspect(got)}"

        ["advance", epoch] ->
          got = Identity.advance(String.to_integer(epoch))

          want =
            case expected do
              ["exhausted"] -> {:error, :exhausted}
              [next] -> {:ok, String.to_integer(next)}
            end

          assert got == want, "#{line} gave #{inspect(got)}"

        ["instances" | entries] ->
          live =
            Enum.map(entries, fn entry ->
              [template, instance, space] = String.split(entry, ":")

              %{
                template: String.to_integer(template),
                instance: String.to_integer(instance),
                space: String.to_integer(space)
              }
            end)

          got = Identity.check_instances(live)

          want =
            case expected do
              ["ok"] -> :ok
              ["space-shared", space] -> {:error, {:space_shared, String.to_integer(space)}}
              ["instance-repeated", id] -> {:error, {:instance_repeated, String.to_integer(id)}}
            end

          assert got == want, "#{line} gave #{inspect(got)}"

        ["placements", space | entries] ->
          checked = %{id: 199, placements: %{330 => {0, 0}, 269 => {74, 0}}}
          claimed_space = String.to_integer(space)

          placements =
            Enum.map(entries, fn entry ->
              [region, map, origin] = String.split(entry, ":")
              [ox, oy] = String.split(origin, ",")

              %{
                region: String.to_integer(region),
                space: claimed_space,
                map: String.to_integer(map),
                origin: {String.to_integer(ox), String.to_integer(oy)}
              }
            end)

          got = Identity.check_placements(checked, placements)

          want =
            case expected do
              ["ok"] ->
                :ok

              ["wrong-space", region] ->
                {:error, {:wrong_space, String.to_integer(region), claimed_space}}

              ["map-not-in-space", region, map] ->
                {:error,
                 {:map_not_in_space, String.to_integer(region), String.to_integer(map)}}

              ["origin-disagrees", region, map] ->
                map_id = String.to_integer(map)
                placement = Enum.find(placements, &(&1.map == map_id))

                {:error,
                 {:origin_disagrees, String.to_integer(region), map_id, placement.origin,
                  Map.fetch!(checked.placements, map_id)}}

              ["map-shared", map] ->
                {:error, {:map_shared, String.to_integer(map)}}
            end

          assert got == want, "#{line} gave #{inspect(got)}"

        ["seamless", kind] ->
          want = expected == ["yes"]

          kind =
            case kind do
              "seam" -> :seam
              "door" -> :door
              "portal" -> :portal
              "teleport" -> :teleport
              "instance" -> :instance
            end

          assert Identity.seamless?(kind) == want, line
      end
    end
  end

  describe "properties the fixture cannot enumerate" do
    test "an exhausted epoch still refuses stale commands rather than accepting everything" do
      installed = Identity.max_epoch()
      assert Identity.advance(installed) == {:error, :exhausted}
      assert Identity.current?(installed, installed)
      refute Identity.current?(0, installed)
      refute Identity.current?(installed - 1, installed)
    end

    test "ownership survives a topology release that moves the space underneath it" do
      # Codex review, 2026-08-23: this test used to assert that two identical literal maps were
      # equal, which proves nothing about stability. Stability means the *same* region keeps
      # authority when the world is recompiled and the ground moves.
      #
      # Two releases of one space. The maps keep their ids and region 330 keeps its authority,
      # but the second release shifts every origin, so the same tile has different global
      # coordinates in each.
      before = %{id: 199, geometry: :plane, placements: %{330 => {148, 160}, 269 => {222, 160}}}
      later = %{id: 199, geometry: :plane, placements: %{330 => {1148, 1160}, 269 => {1222, 1160}}}

      placements_before = [
        %{region: 330, space: 199, map: 330, origin: {148, 160}},
        %{region: 269, space: 199, map: 269, origin: {222, 160}}
      ]

      placements_later = [
        %{region: 330, space: 199, map: 330, origin: {1148, 1160}},
        %{region: 269, space: 199, map: 269, origin: {1222, 1160}}
      ]

      # The owner of a given *tile* is unchanged across the release, even though its
      # coordinates are not: authority follows content, not numbers.
      tile = {330, 87, 65}
      {:ok, was} = Arena.World.Position.to_global(before, tile)
      {:ok, now} = Arena.World.Position.to_global(later, tile)
      refute was == now, "the release moved the ground"

      assert {:ok, 330} = Arena.World.Position.region_at(before, was, placements_before)
      assert {:ok, 330} = Arena.World.Position.region_at(later, now, placements_later)

      # An entity owned by region 330 is still owned by region 330, and a command written
      # under the old release is still valid because ownership did not change hands.
      owner = %{entity: 7, region: 330, epoch: 3}
      assert Identity.may_execute(%{entity: 7, epoch: 3}, owner, :authoritative) == :ok

      # Positions from the two releases are not comparable, which is what the version is for.
      assert Arena.World.Position.compare({before, 1, was}, {later, 2, now}) == :different_version

      # A handoff, by contrast, changes the region and the epoch together.
      {:ok, next} = Identity.advance(3)
      handed_off = %{entity: 7, region: 269, epoch: next}
      assert Identity.may_execute(%{entity: 7, epoch: 3}, handed_off, :authoritative) ==
               {:error, :stale_epoch}

      assert handed_off.entity == owner.entity, "the entity did not become another entity"
      refute handed_off.region == owner.region, "its owner did"
    end

    test "an epoch above u64 is not an epoch" do
      # Restored: `f9aaf016` deleted this while rewriting the test next to it, so the only
      # coverage of above-maximum epochs disappeared in the same commit that claimed to be
      # improving the evidence. Codex re-review, 2026-08-23, caught the regression.
      assert_raise ArgumentError, fn -> Identity.advance(Identity.max_epoch() + 1) end
      assert_raise ArgumentError, fn -> Identity.advance(Identity.max_epoch() * 2) end

      assert Identity.advance(Identity.max_epoch()) == {:error, :exhausted}
      assert Identity.advance(Identity.max_epoch() - 1) == {:ok, Identity.max_epoch()}
    end

    test "an empty instance set is trivially consistent" do
      assert Identity.check_instances([]) == :ok
    end

    test "an unrecognised reach raises rather than becoming read-only by default" do
      # Fail loudly on a programming error. Silently treating an unknown value as the
      # read-only case would be safe and would also hide the mistake forever.
      assert Identity.reaches() == [:authoritative, :observed]

      assert_raise FunctionClauseError, fn ->
        Identity.may_execute(%{entity: 7, epoch: 3}, %{entity: 7, region: 330, epoch: 3}, :maybe)
      end
    end
  end
end
