defmodule ArenaWeb.Router do
  use ArenaWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ArenaWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end
end
