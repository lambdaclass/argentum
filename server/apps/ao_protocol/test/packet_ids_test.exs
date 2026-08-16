defmodule AoProtocol.PacketIdsTest do
  @moduledoc """
  Guards the packet id space.

  Ids are inherited from VB6 and are not contiguous: client ids include
  chat_color (421) and quest_accept (500), so there is no "safely above the
  range" region a new packet can be dropped into. Extensions therefore need a
  declared band, and every id needs to be unique — a collision is silent at
  compile time and shows up as a mis-decoded packet at runtime.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.PacketIds

  defp ids_for(module) do
    module.__info__(:functions)
    |> Enum.filter(fn {name, arity} -> arity == 0 and name != :extension_range end)
    |> Enum.map(fn {name, _} -> {name, apply(module, name, [])} end)
    |> Enum.filter(fn {_, value} -> is_integer(value) end)
  end

  describe "client ids" do
    test "no id is used by two packets" do
      duplicates =
        ids_for(PacketIds.Client)
        |> Enum.group_by(fn {_, id} -> id end)
        |> Enum.filter(fn {_, entries} -> length(entries) > 1 end)

      assert duplicates == [], "duplicate client packet ids: #{inspect(duplicates)}"
    end

    test "ping sits inside the reserved extension band" do
      assert PacketIds.Client.ping() in PacketIds.Client.extension_range()
    end

    test "inherited packets stay out of the extension band" do
      # If a VB6 packet ever lands in 900-999 the band has to move, and this
      # test is the place that says so rather than a runtime mis-decode.
      intruders =
        ids_for(PacketIds.Client)
        |> Enum.filter(fn {name, id} ->
          name != :ping and id in PacketIds.Client.extension_range()
        end)

      assert intruders == [], "non-extension ids inside the extension band: #{inspect(intruders)}"
    end
  end

  describe "server ids" do
    test "no id is used by two packets" do
      duplicates =
        ids_for(PacketIds.Server)
        |> Enum.group_by(fn {_, id} -> id end)
        |> Enum.filter(fn {_, entries} -> length(entries) > 1 end)

      assert duplicates == [], "duplicate server packet ids: #{inspect(duplicates)}"
    end

    test "extensions sit inside the reserved band" do
      for id <- [PacketIds.Server.world_pack_signature(), PacketIds.Server.pong()] do
        assert id in PacketIds.Server.extension_range()
      end
    end
  end

  test "client and server ids are separate spaces and may overlap" do
    # Documenting this on purpose: the spaces are independent, so an id
    # appearing in both is not a collision and must not be "fixed".
    client = ids_for(PacketIds.Client) |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    server = ids_for(PacketIds.Server) |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    assert MapSet.size(MapSet.intersection(client, server)) > 0
  end
end
