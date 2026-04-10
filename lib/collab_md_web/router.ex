defmodule CollabMdWeb.Router do
  use CollabMdWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", CollabMdWeb do
    pipe_through :api
  end
end
