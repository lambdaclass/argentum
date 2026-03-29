import Config

##########################
# General configurations #
##########################

config :logger, level: :info

############################
# App configuration: arena #
############################

config :arena, ArenaWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

###################################
# App configuration: game_backend #
###################################

config :game_backend, GameBackend.Repo,
  url: System.get_env("DATABASE_URL"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 50
