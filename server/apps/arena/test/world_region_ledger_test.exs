defmodule Arena.World.RegionLedgerTest do
  @moduledoc """
  The server's half of the region ledger contract.

  Reads the same hand-authored fixture `ao_core::ledger` reads. Both sides must accept the same
  ledgers, refuse the broken ones with the same named fault, resolve the same map to the same
  region, and issue the same next id — because a `RegionId` that means one thing to the compiler
  and another to the server is not a durable identity, it is two.
  """
  use ExUnit.Case, async: true

  alias Arena.World.RegionLedger

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
              "ledger_contract.txt"
            ])

  defp lines do
    @contract
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(fn line -> line |> String.split("#") |> hd() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  # Every `ledger <name> = ...` line, expanded back into ledger text.
  defp ledgers do
    for line <- lines(), String.starts_with?(line, "ledger "), into: %{} do
      [name, body] = line |> String.replace_prefix("ledger ", "") |> String.split("=", parts: 2)

      text =
        body
        |> String.split("|")
        |> Enum.map(&String.trim/1)
        |> Enum.join("\n")

      {String.trim(name), text}
    end
  end

  defp cases do
    for line <- lines(), not String.starts_with?(line, "ledger ") do
      {line, String.split(line, ~r/\s+/)}
    end
  end

  test "the contract declares real ledgers and is worth checking" do
    assert map_size(ledgers()) >= 12, "expected real ledgers, got #{map_size(ledgers())}"
    assert length(cases()) >= 25, "expected a real contract, got #{length(cases())} cases"
  end

  test "elixir satisfies every case in the ledger contract" do
    ledgers = ledgers()

    for {line, word} <- cases() do
      case word do
        ["valid", name, "->" | expected] ->
          found =
            case RegionLedger.parse(ledgers[name]) do
              {:ok, _} -> "ok"
              {:error, fault} -> RegionLedger.fault_name(fault)
            end

          assert found == Enum.join(expected, " "), line

        ["owner", name, space, map, "->", "none"] ->
          {:ok, ledger} = RegionLedger.parse(ledgers[name])

          assert RegionLedger.owner(ledger, String.to_integer(space), String.to_integer(map)) ==
                   :none,
                 line

        ["owner", name, space, map, "->", region] ->
          {:ok, ledger} = RegionLedger.parse(ledgers[name])

          assert RegionLedger.owner(ledger, String.to_integer(space), String.to_integer(map)) ==
                   {:ok, String.to_integer(region)},
                 line

        ["allocate", name, "space", space | rest] ->
          # `maps` may be absent entirely (an empty list), so the tail is split on the arrow
          # rather than positionally.
          {maps, ["->" | expected]} = Enum.split_while(rest, &(&1 != "->"))
          expected = Enum.join(expected, " ")

          maps =
            maps
            |> Enum.drop(1)
            |> Enum.flat_map(&String.split(&1, ",", trim: true))
            |> Enum.map(&String.to_integer/1)

          {:ok, ledger} = RegionLedger.parse(ledgers[name])
          before = ledger.next_region_id

          case RegionLedger.allocate(ledger, String.to_integer(space), maps) do
            {:ok, issued, after_ledger} ->
              assert Integer.to_string(issued) == expected, line
              assert issued == before, "an id comes from the mark, not from a count"
              assert after_ledger.next_region_id == before + 1, "the mark moves exactly once"

              # Success always leaves another valid ledger.
              assert {:ok, _} = RegionLedger.parse(RegionLedger.encode(after_ledger)), line

            {:error, fault} ->
              assert RegionLedger.fault_name(fault) == expected, line
          end

        ["exhausted-at", mark] ->
          mark = String.to_integer(mark)
          assert RegionLedger.exhausted_at() == mark

          # Built directly rather than through a `ledger` line: accounting requires every id
          # below the mark to be live or spent, so a valid ledger here would need four billion
          # entries. What is under test is the allocator's refusal.
          ledger = %{
            next_region_id: mark,
            active: %{},
            tombstones: %{},
            splits: [],
            merges: []
          }

          assert RegionLedger.next_available(ledger) == :exhausted
          assert RegionLedger.allocate(ledger, 199, [330]) == {:error, {:exhausted, mark}}
      end
    end
  end

  test "a parsed ledger re-encodes to the same bytes" do
    # A release pair is compared byte for byte, so "unchanged" is only checkable if one state
    # has one spelling. Round-tripping every valid ledger in the contract proves the encoder and
    # the parser agree about what that spelling is.
    for {name, text} <- ledgers(), match?({:ok, _}, RegionLedger.parse(text)) do
      {:ok, ledger} = RegionLedger.parse(text)
      {:ok, again} = RegionLedger.parse(RegionLedger.encode(ledger))

      assert ledger == again, "#{name} did not survive a round trip"
      assert RegionLedger.encode(ledger) == RegionLedger.encode(again), "#{name} encodes two ways"
    end
  end
end
