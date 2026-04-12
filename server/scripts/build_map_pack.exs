result = Arena.ClientMapPack.write!()
manifest = result.manifest

Mix.shell().info(
  "Built client map pack: #{manifest.maps} maps, #{manifest.bytes} bytes -> #{Path.relative_to_cwd(result.output_path)}"
)

Enum.each(result.skipped, fn {map_id, reason} ->
  Mix.shell().info("Skipped map #{map_id}: #{inspect(reason)}")
end)
