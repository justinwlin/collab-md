defmodule CollabMdWeb.RoomChannel do
  use CollabMdWeb, :channel

  alias CollabMd.{Room, RoomSupervisor}

  @impl true
  def join("room:" <> code, %{"username" => username}, socket) do
    if RoomSupervisor.room_exists?(code) do
      Room.join(code, username)
      socket = assign(socket, :code, code)
      socket = assign(socket, :username, username)
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "room_not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    code = socket.assigns.code
    {:ok, document} = Room.get_document(code)
    {:ok, status} = Room.status(code)

    push(socket, "doc:state", %{
      "document" => document,
      "version" => status.version
    })

    broadcast!(socket, "user:joined", %{
      "username" => socket.assigns.username,
      "users" => status.users
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("doc:update", %{"document" => content, "author" => author}, socket) do
    code = socket.assigns.code
    {:ok, version} = Room.update_document(code, content, author)

    broadcast_from!(socket, "doc:change", %{
      "document" => content,
      "author" => author,
      "version" => version
    })

    {:reply, {:ok, %{"version" => version}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if Map.has_key?(socket.assigns, :code) do
      Room.leave(socket.assigns.code, socket.assigns.username)

      case Room.status(socket.assigns.code) do
        {:ok, status} ->
          broadcast!(socket, "user:left", %{
            "username" => socket.assigns.username,
            "users" => status.users
          })

        _ ->
          :ok
      end
    end

    :ok
  end
end
