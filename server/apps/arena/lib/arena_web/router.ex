defmodule ArenaWeb.Router do
  use ArenaWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  scope "/api", ArenaWeb do
    pipe_through :api

    get "/health", HealthController, :check
    get "/auth/session", BrowserApiController, :session
    post "/auth/register", BrowserApiController, :register
    post "/auth/login", BrowserApiController, :login
    post "/auth/logout", BrowserApiController, :logout
    get "/meta/character-options", BrowserApiController, :character_options
    get "/meta/world-pack", BrowserApiController, :world_pack
    get "/meta/online", BrowserApiController, :online
    get "/characters", BrowserApiController, :list_characters
    post "/characters", BrowserApiController, :create_character
    post "/characters/:id/session", BrowserApiController, :create_character_session
    get "/ranking/general", BrowserApiController, :ranking
  end

  # SPA catch-all: serve index.html for any non-API, non-static path
  get "/", ArenaWeb.SpaController, :index
  get "/*path", ArenaWeb.SpaController, :index
end
