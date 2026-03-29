import Config

project_root =
  System.get_env("ARGENTUM_PROJECT_ROOT") ||
    case System.get_env("RELEASE_ROOT") do
      nil -> Path.expand("..", File.cwd!())
      release_root -> Path.expand("..", release_root)
    end

resources_root =
  System.get_env("ARGENTUM_RESOURCES_DIR") ||
    Path.join(project_root, "resources")

client_root =
  System.get_env("ARGENTUM_CLIENT_DIR") ||
    Path.join(project_root, "client")

old_root =
  System.get_env("ARGENTUM_OLD_DIR") ||
    Path.join(project_root, "old")

config :arena,
  dat_dir: Path.join(resources_root, "raw/Dat"),
  maps_dir: Path.join(resources_root, "raw/Mapas")

config :ao_tcp_gateway,
  webclient_dir: Path.join(old_root, "clients/webclient/ao-web-client/client"),
  graphics_dir: Path.join(resources_root, "raw/Graficos"),
  char_graphics_dir: Path.join(resources_root, "graficos_char"),
  indices_dir: Path.join(resources_root, "indices"),
  midi_dir: Path.join(resources_root, "raw/midi"),
  sounds_dir: Path.join(resources_root, "raw/SoundsOgg"),
  serious_client_dir: Path.join(client_root, "dist")

############################
# App configuration: arena #
############################

# Visibility mode: aoi_grid (default), aoi_scan, or global
# Set AO_VISIBILITY_MODE=global to benchmark without AoI
case System.get_env("AO_VISIBILITY_MODE") do
  "global" -> config :arena, visibility_mode: :global
  "aoi_scan" -> config :arena, visibility_mode: :aoi_scan
  "aoi_grid" -> config :arena, visibility_mode: :aoi_grid
  _ -> :ok
end

if System.get_env("PHX_SERVER") do
  config :arena, ArenaWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "3000")

  config :arena, ArenaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
