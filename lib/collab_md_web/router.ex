defmodule CollabMdWeb.Router do
  use CollabMdWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", CollabMdWeb do
    pipe_through :api

    post "/rooms", RoomController, :create
    get "/rooms/:code/document", RoomController, :get_document
    put "/rooms/:code/document", RoomController, :update_document
    get "/rooms/:code/versions", RoomController, :versions
    put "/rooms/:code/restore/:version", RoomController, :restore
    get "/rooms/:code/status", RoomController, :status
  end
end
