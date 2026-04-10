defmodule CollabMdWeb.RoomControllerTest do
  use CollabMdWeb.ConnCase

  alias CollabMd.RoomSupervisor

  describe "POST /api/rooms" do
    test "creates a room and returns code", %{conn: conn} do
      conn = post(conn, ~p"/api/rooms")
      assert %{"code" => code} = json_response(conn, 201)
      assert String.length(code) == 6
    end
  end

  describe "GET /api/rooms/:code/document" do
    test "returns current document", %{conn: conn} do
      {:ok, code} = RoomSupervisor.create_room()
      conn = get(conn, ~p"/api/rooms/#{code}/document")
      assert %{"document" => "", "version" => 0} = json_response(conn, 200)
    end

    test "returns 404 for nonexistent room", %{conn: conn} do
      conn = get(conn, ~p"/api/rooms/nope00/document")
      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/rooms/:code/document" do
    test "updates document and returns version", %{conn: conn} do
      {:ok, code} = RoomSupervisor.create_room()
      conn = put(conn, ~p"/api/rooms/#{code}/document", %{
        "document" => "# Hello",
        "author" => "claude"
      })
      assert %{"version" => 1} = json_response(conn, 200)

      # Verify it was saved
      conn = get(build_conn(), ~p"/api/rooms/#{code}/document")
      assert %{"document" => "# Hello"} = json_response(conn, 200)
    end
  end

  describe "GET /api/rooms/:code/versions" do
    test "returns version history", %{conn: conn} do
      {:ok, code} = RoomSupervisor.create_room()
      CollabMd.Room.update_document(code, "v1", "alice")
      CollabMd.Room.update_document(code, "v2", "bob")

      conn = get(conn, ~p"/api/rooms/#{code}/versions")
      assert %{"versions" => versions} = json_response(conn, 200)
      assert length(versions) == 2
    end
  end

  describe "PUT /api/rooms/:code/restore/:version" do
    test "restores a previous version", %{conn: conn} do
      {:ok, code} = RoomSupervisor.create_room()
      CollabMd.Room.update_document(code, "original", "alice")
      CollabMd.Room.update_document(code, "changed", "bob")

      conn = put(conn, ~p"/api/rooms/#{code}/restore/1")
      assert %{"document" => "original"} = json_response(conn, 200)
    end

    test "returns 404 for nonexistent version", %{conn: conn} do
      {:ok, code} = RoomSupervisor.create_room()
      conn = put(conn, ~p"/api/rooms/#{code}/restore/999")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/rooms/:code/status" do
    test "returns room status", %{conn: conn} do
      {:ok, code} = RoomSupervisor.create_room()
      conn = get(conn, ~p"/api/rooms/#{code}/status")
      assert %{"users" => [], "version" => 0} = json_response(conn, 200)
    end
  end
end
