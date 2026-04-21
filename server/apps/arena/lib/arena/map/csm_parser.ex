defmodule Arena.Map.CsmParser do
  @moduledoc """
  Parses Argentum Online .csm (Custom Screen Map) binary files.

  Binary format (all little-endian):
  - Header: 10 x Int32 (blocked count, 4 layer counts, triggers, lights, particles, NPCs, objects, tile exits)
  - MapSize: 4 x Int16 (XMax, XMin, YMax, YMin — usually unused)
  - MapDat: variable-length metadata (map name, zone, terrain, flags, etc.)
  - Tile data sections: blocked, layers 1-4, triggers, particles, lights, objects, NPCs, tile exits

  VB6 Integer = 2 bytes signed little-endian
  VB6 Long = 4 bytes signed little-endian
  VB6 Byte = 1 byte unsigned
  VB6 String = 2-byte length prefix + bytes (in Binary mode via Get)

  All positional records in CSM files use 1-based coordinates (VB6
  convention). The runtime preserves 1-based coordinates throughout
  to match the original VB6 server.
  """

  defmodule MapData do
    @moduledoc "Parsed map data from a .csm file."
    defstruct [
      :map_name,
      :zone,
      :terrain,
      :safe_zone,
      :music_hi,
      :music_low,
      :rain,
      :snow,
      :fog,
      # VB6 FileIO.bas:1754-1760: MapInfo(Map).Salida parsed from the
      # "map-x-y" string stored in MapDat.  `nil` or %{map: 0} means
      # no Salida is configured for this map.
      salida: nil,
      restrict_mode: "",
      blocked: [],
      layers: [[], [], [], []],
      triggers: [],
      npcs: [],
      objects: [],
      tile_exits: [],
      tiles: nil
    ]
  end

  alias Arena.Map.Helpers

  # Block flags from Declares.bas — used by tile grid NIF and movement checks
  # @block_north 0x01
  # @block_east 0x02
  # @block_south 0x04
  # @block_west 0x08
  # @block_all_sides 0x0F
  # @block_gm 0x10
  # @flag_agua 0x20
  # @flag_arbol 0x40

  @doc """
  Parse a .csm file and return a MapData struct with tile grid.
  The tile grid is a flat list of 10000 bytes (100x100):
  - 0 = walkable
  - non-zero = blocked (the byte holds the block flags)
  """
  def parse_file(path) do
    case File.read(path) do
      {:ok, data} -> parse(data)
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(data) do
    with {:ok, header, rest} <- parse_header(data),
         {:ok, _map_size, rest} <- parse_map_size(rest),
         {:ok, map_dat, rest} <- parse_map_dat(rest),
         {:ok, sections, _rest} <- parse_sections(header, rest) do
      # Build the tile grid
      tiles = build_tile_grid(sections)

      {:ok,
       %MapData{
         map_name: map_dat.map_name,
         zone: map_dat.zone,
         terrain: map_dat.terrain,
         safe_zone: map_dat.safe_zone,
         music_hi: map_dat.music_hi,
         music_low: map_dat.music_low,
         rain: map_dat.rain,
         snow: map_dat.snow,
         fog: map_dat.fog,
         salida: map_dat.salida,
         restrict_mode: map_dat.restrict_mode,
         blocked: sections.blocked,
         layers: sections.layers,
         triggers: sections.triggers,
         npcs: sections.npcs,
         objects: sections.objects,
         tile_exits: sections.tile_exits,
         tiles: tiles
       }}
    end
  end

  # ---- Header: 10 x Int32 ----

  defp parse_header(<<
         num_blocked::little-signed-32,
         num_layer1::little-signed-32,
         num_layer2::little-signed-32,
         num_layer3::little-signed-32,
         num_layer4::little-signed-32,
         num_triggers::little-signed-32,
         num_lights::little-signed-32,
         num_particles::little-signed-32,
         num_npcs::little-signed-32,
         num_objects::little-signed-32,
         num_te::little-signed-32,
         rest::binary
       >>) do
    header = %{
      num_blocked: num_blocked,
      num_layers: [num_layer1, num_layer2, num_layer3, num_layer4],
      num_triggers: num_triggers,
      num_lights: num_lights,
      num_particles: num_particles,
      num_npcs: num_npcs,
      num_objects: num_objects,
      num_te: num_te
    }

    {:ok, header, rest}
  end

  defp parse_header(_), do: {:error, :invalid_header}

  # ---- MapSize: 4 x Int16 ----

  defp parse_map_size(<<
         x_max::little-signed-16,
         x_min::little-signed-16,
         y_max::little-signed-16,
         y_min::little-signed-16,
         rest::binary
       >>) do
    {:ok, %{x_max: x_max, x_min: x_min, y_max: y_max, y_min: y_min}, rest}
  end

  defp parse_map_size(_), do: {:error, :invalid_map_size}

  # ---- MapDat: variable-length metadata ----
  # VB6 Binary Get reads strings as: 2-byte length + bytes

  defp parse_map_dat(data) do
    with {:ok, map_name, rest} <- read_vb6_string(data),
         {:ok, _backup_mode, rest} <- read_byte(rest),
         {:ok, restrict_mode, rest} <- read_vb6_string(rest),
         {:ok, music_hi, rest} <- read_int32(rest),
         {:ok, music_low, rest} <- read_int32(rest),
         {:ok, seguro, rest} <- read_byte(rest),
         {:ok, zone, rest} <- read_vb6_string(rest),
         {:ok, terrain, rest} <- read_vb6_string(rest),
         {:ok, _ambient, rest} <- read_vb6_string(rest),
         {:ok, _base_light, rest} <- read_int32(rest),
         {:ok, _letter_grh, rest} <- read_int32(rest),
         {:ok, _level, rest} <- read_int32(rest),
         {:ok, _extra2, rest} <- read_int32(rest),
         {:ok, salida_str, rest} <- read_vb6_string(rest),
         {:ok, lluvia, rest} <- read_byte(rest),
         {:ok, nieve, rest} <- read_byte(rest),
         {:ok, niebla, rest} <- read_byte(rest) do
      map_dat = %{
        map_name: map_name,
        zone: zone,
        terrain: terrain,
        safe_zone: seguro != 0,
        music_hi: music_hi,
        music_low: music_low,
        rain: lluvia != 0,
        snow: nieve != 0,
        fog: niebla != 0,
        salida: parse_salida(salida_str),
        restrict_mode: String.upcase(restrict_mode)
      }

      {:ok, map_dat, rest}
    end
  end

  # VB6 FileIO.bas:1754-1760 — Salida stored as "map-x-y" string.
  # Empty or malformed strings translate to `nil` (no Salida configured).
  defp parse_salida(""), do: nil
  defp parse_salida(nil), do: nil

  defp parse_salida(str) when is_binary(str) do
    case String.split(str, "-") do
      [m, x, y | _] ->
        with {map_id, _} <- Integer.parse(m),
             {xi, _} <- Integer.parse(x),
             {yi, _} <- Integer.parse(y) do
          %{map: map_id, x: xi, y: yi}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_salida(_), do: nil

  # ---- Tile data sections ----

  defp parse_sections(header, data) do
    with {:ok, blocked, rest} <- parse_blocked(header.num_blocked, data),
         {:ok, layer1, rest} <- parse_grh_layer(Enum.at(header.num_layers, 0), rest),
         {:ok, layer2, rest} <- parse_grh_layer(Enum.at(header.num_layers, 1), rest),
         {:ok, layer3, rest} <- parse_grh_layer(Enum.at(header.num_layers, 2), rest),
         {:ok, layer4, rest} <- parse_grh_layer(Enum.at(header.num_layers, 3), rest),
         {:ok, triggers, rest} <- parse_triggers(header.num_triggers, rest),
         {:ok, _particles, rest} <- parse_particles(header.num_particles, rest),
         {:ok, _lights, rest} <- parse_lights(header.num_lights, rest),
         {:ok, objects, rest} <- parse_objects(header.num_objects, rest),
         {:ok, npcs, rest} <- parse_npcs(header.num_npcs, rest),
         {:ok, tile_exits, rest} <- parse_tile_exits(header.num_te, rest) do
      {:ok,
       %{
         blocked: blocked,
         layers: [layer1, layer2, layer3, layer4],
         triggers: triggers,
         npcs: npcs,
         objects: objects,
         tile_exits: tile_exits
       }, rest}
    end
  end

  # t_DatosBloqueados: x(Int16) + y(Int16) + Lados(Byte) = 5 bytes
  defp parse_blocked(0, rest), do: {:ok, [], rest}

  defp parse_blocked(count, data) do
    parse_n(count, data, 5, fn <<x::little-signed-16, y::little-signed-16, lados::8>> ->
      %{x: x, y: y, blocked: lados}
    end)
  end

  # t_DatosGrh: x(Int16) + y(Int16) + GrhIndex(Int32) = 8 bytes
  defp parse_grh_layer(0, rest), do: {:ok, [], rest}

  defp parse_grh_layer(count, data) do
    parse_n(count, data, 8, fn <<x::little-signed-16, y::little-signed-16, grh::little-signed-32>> ->
      %{x: x, y: y, grh_index: grh}
    end)
  end

  # t_DatosTrigger: x(Int16) + y(Int16) + trigger(Int16) = 6 bytes
  defp parse_triggers(0, rest), do: {:ok, [], rest}

  defp parse_triggers(count, data) do
    parse_n(count, data, 6, fn <<x::little-signed-16, y::little-signed-16, trigger::little-signed-16>> ->
      %{x: x, y: y, trigger: trigger}
    end)
  end

  # t_DatosParticulas: x(Int16) + y(Int16) + Particula(Int32) = 8 bytes
  defp parse_particles(0, rest), do: {:ok, [], rest}

  defp parse_particles(count, data) do
    parse_n(count, data, 8, fn <<x::little-signed-16, y::little-signed-16, _::little-signed-32>> ->
      %{x: x, y: y}
    end)
  end

  # t_DatosLuces: x(Int16) + y(Int16) + Color(Int32) + Rango(Byte) = 9 bytes
  defp parse_lights(0, rest), do: {:ok, [], rest}

  defp parse_lights(count, data) do
    parse_n(count, data, 9, fn <<x::little-signed-16, y::little-signed-16, _color::little-signed-32, _rango::8>> ->
      %{x: x, y: y}
    end)
  end

  # t_DatosObjs: x(Int16) + y(Int16) + ObjIndex(Int16) + ObjAmmount(Int16) = 8 bytes
  defp parse_objects(0, rest), do: {:ok, [], rest}

  defp parse_objects(count, data) do
    parse_n(count, data, 8, fn <<x::little-signed-16, y::little-signed-16, obj_index::little-signed-16,
                                 amount::little-signed-16>> ->
      %{x: x, y: y, obj_index: obj_index, amount: amount}
    end)
  end

  # t_DatosNPC: x(Int16) + y(Int16) + NpcIndex(Int16) = 6 bytes
  defp parse_npcs(0, rest), do: {:ok, [], rest}

  defp parse_npcs(count, data) do
    parse_n(count, data, 6, fn <<x::little-signed-16, y::little-signed-16, npc_index::little-signed-16>> ->
      %{x: x, y: y, npc_index: npc_index}
    end)
  end

  # t_DatosTE: x(Int16) + y(Int16) + DestM(Int16) + DestX(Int16) + DestY(Int16) = 10 bytes
  defp parse_tile_exits(0, rest), do: {:ok, [], rest}

  defp parse_tile_exits(count, data) do
    parse_n(count, data, 10, fn <<x::little-signed-16, y::little-signed-16, dest_map::little-signed-16,
                                  dest_x::little-signed-16, dest_y::little-signed-16>> ->
      %{x: x, y: y, dest_map: dest_map, dest_x: dest_x, dest_y: dest_y}
    end)
  end

  # ---- Generic N-record parser ----

  defp parse_n(count, data, record_size, parse_fn) do
    total_bytes = count * record_size

    case data do
      <<records::binary-size(total_bytes), rest::binary>> ->
        items =
          for <<chunk::binary-size(record_size) <- records>> do
            parse_fn.(chunk)
          end

        {:ok, items, rest}

      _ ->
        {:error, {:insufficient_data, count, record_size, byte_size(data)}}
    end
  end

  # ---- Build tile grid ----

  # VB6 water tile detection: layer 1 GRH in these ranges AND layer 2 empty
  # (bridges on layer 2 make the tile walkable, not water)
  @water_grh_ranges [{1505, 1520}, {5665, 5680}, {13547, 13562}]

  defp build_tile_grid(sections) do
    w = Helpers.map_width()
    # Start with all tiles walkable (0)
    grid = :array.new(w * Helpers.map_height(), default: 0)

    # Build layer 1 and layer 2 lookup maps for water detection
    l1_map =
      sections.layers
      |> Enum.at(0, [])
      |> Map.new(fn %{x: x, y: y, grh_index: g} -> {{x, y}, g} end)

    l2_map =
      sections.layers
      |> Enum.at(1, [])
      |> Map.new(fn %{x: x, y: y, grh_index: g} -> {{x, y}, g} end)

    # Mark water tiles (value 2) from layer 1 GRH indices
    grid =
      Enum.reduce(l1_map, grid, fn {{x, y}, grh}, grid ->
        if valid_pos?(x, y) and water_grh?(grh) and not Map.has_key?(l2_map, {x, y}) do
          idx = (y - 1) * w + (x - 1)
          :array.set(idx, 2, grid)
        else
          grid
        end
      end)

    # Apply blocked tiles (overrides water where both exist)
    grid =
      Enum.reduce(sections.blocked, grid, fn %{x: x, y: y, blocked: _lados}, grid ->
        if valid_pos?(x, y) do
          idx = (y - 1) * w + (x - 1)
          # Normalize to 1 (blocked) — raw lados values like 2 would collide
          # with the water tile value (2) and confuse the NIF/movement code
          :array.set(idx, 1, grid)
        else
          grid
        end
      end)

    # Convert to flat list
    :array.to_list(grid)
  end

  defp water_grh?(grh) do
    Enum.any?(@water_grh_ranges, fn {lo, hi} -> grh >= lo and grh <= hi end)
  end

  defp valid_pos?(x, y), do: x >= 1 and x <= Helpers.map_width() and y >= 1 and y <= Helpers.map_height()

  # ---- Binary reading helpers ----
  # VB6 Binary Get reads strings as 2-byte length prefix + bytes

  defp read_vb6_string(<<len::little-signed-16, str::binary-size(len), rest::binary>>) when len >= 0 do
    {:ok, str, rest}
  end

  defp read_vb6_string(<<0::little-signed-16, rest::binary>>), do: {:ok, "", rest}
  defp read_vb6_string(_), do: {:error, :invalid_string}

  defp read_byte(<<b::8, rest::binary>>), do: {:ok, b, rest}
  defp read_byte(_), do: {:error, :unexpected_eof}

  defp read_int32(<<v::little-signed-32, rest::binary>>), do: {:ok, v, rest}
  defp read_int32(_), do: {:error, :unexpected_eof}
end
