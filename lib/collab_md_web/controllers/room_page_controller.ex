defmodule CollabMdWeb.RoomPageController do
  use CollabMdWeb, :controller

  alias CollabMd.RoomSupervisor

  def show(conn, %{"code" => code}) do
    if RoomSupervisor.room_exists?(code) do
      html_path = Application.app_dir(:collab_md, "priv/static/room.html")

      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, html_path)
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(404, """
      <!DOCTYPE html>
      <html><head><title>Room not found</title>
      <style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;background:#1a1a2e;color:#e0e0e0;}</style>
      </head><body><div><h1>Room not found</h1><p>Code <code>#{code}</code> doesn't exist or has expired.</p></div></body></html>
      """)
    end
  end
end
