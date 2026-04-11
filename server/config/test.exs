import Config

##########################
# General configurations #
##########################

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

############################
# App configuration: arena #
############################

# Use global visibility in most tests so broadcast tests aren't affected by spawn distance.
# AoI ranges use production values (11x9) so the aoi_visibility_test can validate real culling.
config :arena,
  visibility_mode: :global,
  aoi_range_x: 11,
  aoi_range_y: 9

config :arena, ArenaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QK4nHna6CWP5+KH2khYXzdIAM2GmQ1B7xwDP6fdjhQro1659xfFvC+69Joj/dKyw",
  server: false

###################################
# App configuration: game_backend #
###################################

config :game_backend, GameBackend.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "argentum_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
