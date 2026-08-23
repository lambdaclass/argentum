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
    assert kinds == ["advance", "execute", "instances", "seamless"]
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

    test "ownership survives a region restart, because a region id is not a process" do
      # Stability is the whole claim of `RegionId`. Restarting the owner does not make it a
      # different owner, so an entity's home is still its home -- what changes on a handoff is
      # the region, and what changes on a restart is nothing.
      before = %{entity: 7, region: 330, epoch: 3}
      after_restart = %{entity: 7, region: 330, epoch: 3}
      assert before == after_restart

      command = %{entity: 7, epoch: 3}
      assert Identity.may_execute(command, after_restart, :authoritative) == :ok

      # A handoff, by contrast, changes both the region and the epoch.
      {:ok, next} = Identity.advance(3)
      handed_off = %{entity: 7, region: 269, epoch: next}
      assert Identity.may_execute(command, handed_off, :authoritative) == {:error, :stale_epoch}
      refute handed_off.region == before.region
      assert handed_off.entity == before.entity
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
