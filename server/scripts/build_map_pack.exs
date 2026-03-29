defmodule ClientMapPackBuilder do
  alias Jason

  @magic "AOMP"
  @version 1
  @map_width 100
  @map_height 100

  def run do
    root = File.cwd!()
    maps_dir =
      Application.get_env(:arena, :maps_dir, "../resources/raw/Mapas")
      |> Path.expand(root)

    data_dir = Path.join(root, "../client/public/data")
    packs_dir = Path.join(data_dir, "packs")
    File.mkdir_p!(packs_dir)
    File.rm_rf!(Path.join(data_dir, "maps.pack"))

    {maps, skipped} =
      maps_dir
      |> discover_map_files()
      |> Enum.reduce({[], []}, fn {map_id, path}, {ok, bad} ->
        case Arena.Map.CsmParser.parse_file(path) do
          {:ok, map_data} -> {[{map_id, map_data} | ok], bad}
          {:error, reason} -> {ok, [{map_id, reason} | bad]}
        end
      end)

    maps = Enum.sort_by(maps, &elem(&1, 0))
    skipped = Enum.sort_by(skipped, &elem(&1, 0))

    if maps == [] do
      Mix.raise("No valid maps found in #{maps_dir}")
    end

    pack =
      IO.iodata_to_binary([
        @magic,
        <<@version::little-unsigned-16, length(maps)::little-unsigned-16>>,
        Enum.map(maps, &encode_map/1)
      ])

    hash =
      :crypto.hash(:sha256, pack)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    filename = "maps.#{hash}.pack"
    output_path = Path.join(packs_dir, filename)
    gzip_path = output_path <> ".gz"
    manifest_path = Path.join(data_dir, "map-pack.json")

    remove_stale_packs(packs_dir, filename)
    File.write!(output_path, pack)
    File.write!(gzip_path, :zlib.gzip(pack))

    manifest =
      Jason.encode!(%{
        filename: filename,
        hash: hash,
        bytes: byte_size(pack),
        maps: length(maps),
        version: @version
      })

    File.write!(manifest_path, manifest)

    Mix.shell().info(
      "Built client map pack: #{length(maps)} maps, #{byte_size(pack)} bytes -> #{Path.relative_to_cwd(output_path)}"
    )

    Enum.each(skipped, fn {map_id, reason} ->
      Mix.shell().info("Skipped map #{map_id}: #{inspect(reason)}")
    end)
  end

  defp discover_map_files(maps_dir) do
    case File.ls(maps_dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^mapa(\d+)\.csm$/i, name) do
            [_, id] -> [{String.to_integer(id), Path.join(maps_dir, name)}]
            _ -> []
          end
        end)

      {:error, reason} ->
        Mix.raise("Cannot read maps directory #{maps_dir}: #{inspect(reason)}")
    end
  end

  defp encode_map({map_id, map_data}) do
    [
      <<map_id::little-unsigned-16>>,
      encode_string(map_data.map_name || "Map #{map_id}"),
      <<@map_width::little-unsigned-16, @map_height::little-unsigned-16>>,
      <<map_data.music_hi::little-signed-32, map_data.music_low::little-signed-32>>,
      :erlang.list_to_binary(map_data.tiles),
      Enum.map(map_data.layers, &encode_layer/1),
      encode_npcs(map_data.npcs),
      encode_objects(map_data.objects),
      encode_tile_exits(map_data.tile_exits)
    ]
  end

  defp encode_string(value) when is_binary(value) do
    <<byte_size(value)::little-unsigned-16, value::binary>>
  end

  defp encode_layer(layer) do
    [
      <<length(layer)::little-unsigned-16>>,
      Enum.map(layer, fn %{x: x, y: y, grh_index: grh_index} ->
        <<x::unsigned-8, y::unsigned-8, grh_index::little-signed-32>>
      end)
    ]
  end

  defp encode_npcs(npcs) do
    [
      <<length(npcs)::little-unsigned-16>>,
      Enum.map(npcs, fn %{x: x, y: y, npc_index: npc_index} ->
        <<x::unsigned-8, y::unsigned-8, npc_index::little-unsigned-16>>
      end)
    ]
  end

  defp encode_objects(objects) do
    [
      <<length(objects)::little-unsigned-16>>,
      Enum.map(objects, fn %{x: x, y: y, obj_index: obj_index, amount: amount} ->
        <<x::unsigned-8, y::unsigned-8, obj_index::little-unsigned-16, amount::little-unsigned-16>>
      end)
    ]
  end

  defp encode_tile_exits(tile_exits) do
    [
      <<length(tile_exits)::little-unsigned-16>>,
      Enum.map(tile_exits, fn %{x: x, y: y, dest_map: dest_map, dest_x: dest_x, dest_y: dest_y} ->
        <<x::unsigned-8, y::unsigned-8, dest_map::little-unsigned-16, dest_x::unsigned-8, dest_y::unsigned-8>>
      end)
    ]
  end

  defp remove_stale_packs(packs_dir, keep_filename) do
    case File.ls(packs_dir) do
      {:ok, files} ->
        keep_files = MapSet.new([keep_filename, keep_filename <> ".gz"])

        Enum.each(files, fn filename ->
          if stale_pack_file?(filename) and not MapSet.member?(keep_files, filename) do
            File.rm_rf!(Path.join(packs_dir, filename))
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp stale_pack_file?(filename) do
    String.ends_with?(filename, ".pack") or String.ends_with?(filename, ".pack.gz")
  end
end

ClientMapPackBuilder.run()
