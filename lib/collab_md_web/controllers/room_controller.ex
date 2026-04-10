defmodule CollabMdWeb.RoomController do
  use CollabMdWeb, :controller

  alias CollabMd.{Room, RoomSupervisor}

  def create(conn, _params) do
    {:ok, code} = RoomSupervisor.create_room()
    conn |> put_status(:created) |> json(%{code: code})
  end

  def get_document(conn, %{"code" => code}) do
    with true <- RoomSupervisor.room_exists?(code),
         {:ok, document} <- Room.get_document(code),
         {:ok, status} <- Room.status(code) do
      json(conn, %{document: document, version: status.version})
    else
      false -> conn |> put_status(:not_found) |> json(%{error: "room_not_found"})
    end
  end

  def update_document(conn, %{"code" => code, "document" => content} = params) do
    author = Map.get(params, "author", "anonymous")

    with true <- RoomSupervisor.room_exists?(code),
         {:ok, version} <- Room.update_document(code, content, author) do
      CollabMdWeb.Endpoint.broadcast!("room:#{code}", "doc:change", %{
        "document" => content,
        "author" => author,
        "version" => version
      })
      json(conn, %{version: version})
    else
      false -> conn |> put_status(:not_found) |> json(%{error: "room_not_found"})
    end
  end

  def versions(conn, %{"code" => code}) do
    with true <- RoomSupervisor.room_exists?(code),
         {:ok, versions} <- Room.get_versions(code) do
      json(conn, %{versions: versions})
    else
      false -> conn |> put_status(:not_found) |> json(%{error: "room_not_found"})
    end
  end

  def restore(conn, %{"code" => code, "version" => version_str}) do
    version = String.to_integer(version_str)

    with true <- RoomSupervisor.room_exists?(code),
         {:ok, document} <- Room.restore_version(code, version) do
      CollabMdWeb.Endpoint.broadcast!("room:#{code}", "doc:change", %{
        "document" => document,
        "author" => "system:restore",
        "version" => version
      })
      json(conn, %{document: document})
    else
      false -> conn |> put_status(:not_found) |> json(%{error: "room_not_found"})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "version_not_found"})
    end
  end

  def status(conn, %{"code" => code}) do
    with true <- RoomSupervisor.room_exists?(code),
         {:ok, status} <- Room.status(code) do
      json(conn, status)
    else
      false -> conn |> put_status(:not_found) |> json(%{error: "room_not_found"})
    end
  end
end
