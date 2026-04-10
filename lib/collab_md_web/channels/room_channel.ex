defmodule CollabMdWeb.RoomChannel do
  use CollabMdWeb, :channel

  alias CollabMd.{RateLimiter, Room, RoomSupervisor}

  # Max 60 document updates per minute per user
  @update_limit 60
  @update_window 60

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

    {:ok, crdt_updates} = Room.get_crdt_state(code)

    push(socket, "doc:state", %{
      "document" => document,
      "version" => status.version,
      "crdt_updates" => Enum.map(crdt_updates, &Base.encode64/1)
    })

    broadcast!(socket, "user:joined", %{
      "username" => socket.assigns.username,
      "users" => status.users
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("doc:update", %{"document" => content, "author" => author}, socket) do
    with :ok <- check_update_rate(socket) do
      code = socket.assigns.code
      {:ok, version} = Room.update_document(code, content, author)

      broadcast_from!(socket, "doc:change", %{
        "document" => content,
        "author" => author,
        "version" => version
      })

      {:reply, {:ok, %{"version" => version}}, socket}
    end
  end

  def handle_in("doc:crdt_update", %{"update" => update_b64, "text" => text, "author" => author}, socket) do
    with :ok <- check_update_rate(socket) do
      code = socket.assigns.code
      update_binary = Base.decode64!(update_b64)
      {:ok, version} = Room.apply_crdt_update(code, update_binary, text, author)

      broadcast_from!(socket, "doc:crdt_update", %{
        "update" => update_b64,
        "author" => author,
        "version" => version
      })

      {:reply, {:ok, %{"version" => version}}, socket}
    end
  end

  def handle_in("doc:patch", %{"ops" => ops, "author" => author, "base_version" => base_version}, socket) do
    code = socket.assigns.code

    case Room.apply_patch(code, ops, author, base_version) do
      {:ok, version} ->
        broadcast_from!(socket, "doc:patch_broadcast", %{
          "ops" => ops,
          "author" => author,
          "version" => version
        })

        {:reply, {:ok, %{"version" => version}}, socket}

      {:error, :version_mismatch, current_doc, current_version} ->
        {:reply,
         {:ok,
          %{
            "version_mismatch" => true,
            "document" => current_doc,
            "version" => current_version
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
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

  defp check_update_rate(socket) do
    key = {:channel_update, socket.assigns.code, socket.assigns.username}

    case RateLimiter.check_rate(key, @update_limit, @update_window) do
      :ok -> :ok
      {:error, :rate_limited} -> {:reply, {:error, %{"reason" => "rate_limited"}}, socket}
    end
  end
end
