import Config

##########################
# General configurations #
##########################

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

############################
# App configuration: arena #
############################

config :arena, ArenaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "0zq8I9ztj7kj4cLdFmvduHwXQJJi9yzNUAUFAlKHkdXS/nJkxUvNPjlSdJPDSUf5"

config :arena, dev_routes: true

###################################
# App configuration: game_backend #
###################################

config :game_backend, GameBackend.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "argentum_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 50
