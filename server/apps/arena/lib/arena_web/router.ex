defmodule ArenaWeb.Router do
  use ArenaWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ArenaWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  # SPA catch-all: serve index.html for any non-API, non-static path
  get "/", ArenaWeb.SpaController, :index
  get "/*path", ArenaWeb.SpaController, :index
end
