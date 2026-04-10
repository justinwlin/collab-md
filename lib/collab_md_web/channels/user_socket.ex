defmodule CollabMdWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", CollabMdWeb.RoomChannel

  @impl true
  def connect(params, socket, _connect_info) do
    {:ok, assign(socket, :username, Map.get(params, "username", "anonymous"))}
  end

  @impl true
  def id(socket), do: "user:#{socket.assigns.username}"
end
