import Config

##########################
# General configurations #
##########################

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

############################
# App configuration: arena #
############################

config :arena,
  visibility_mode: :aoi_grid,
  # :eager = boot all maps from disk at startup (default)
  # :lazy  = boot maps on demand when a player enters
  boot_mode: :eager

config :arena, ArenaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: ArenaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Arena.PubSub,
  live_view: [signing_salt: "XED/NEZq"]

###################################
# App configuration: game_backend #
###################################

config :game_backend,
  ecto_repos: [GameBackend.Repo],
  generators: [timestamp_type: :utc_datetime]

############################
# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
