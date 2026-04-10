defmodule CollabMdWeb.RoomChannelTest do
  use CollabMdWeb.ChannelCase

  alias CollabMd.RoomSupervisor

  setup do
    {:ok, code} = RoomSupervisor.create_room()

    {:ok, _, socket} =
      CollabMdWeb.UserSocket
      |> socket("user", %{username: "alice"})
      |> subscribe_and_join(CollabMdWeb.RoomChannel, "room:#{code}", %{"username" => "alice"})

    %{socket: socket, code: code}
  end

  test "joining sends current document state", %{socket: _socket} do
    assert_push "doc:state", %{"document" => "", "version" => _}
  end

  test "joining broadcasts user:joined", %{socket: _socket} do
    assert_broadcast "user:joined", %{"username" => "alice", "users" => users}
    assert "alice" in users
  end

  test "doc:update broadcasts doc:change to others", %{socket: socket} do
    ref = push(socket, "doc:update", %{"document" => "# Hello", "author" => "alice"})
    assert_reply ref, :ok, %{"version" => version}
    assert is_integer(version)
    assert_broadcast "doc:change", %{"document" => "# Hello", "author" => "alice"}
  end

  test "doc:patch broadcasts doc:patch_broadcast to others", %{socket: socket, code: code} do
    # Seed some content first
    CollabMd.Room.update_document(code, "line 1\nline 2\n", "setup")

    ops = [
      %{"op" => "equal", "content" => "line 1\n"},
      %{"op" => "delete", "content" => "line 2\n"},
      %{"op" => "insert", "content" => "modified\n"}
    ]

    ref = push(socket, "doc:patch", %{"ops" => ops, "author" => "alice", "base_version" => 1})
    assert_reply ref, :ok, %{"version" => version}
    assert is_integer(version)
    assert version > 1

    assert_broadcast "doc:patch_broadcast", %{
      "ops" => ^ops,
      "author" => "alice",
      "version" => ^version
    }
  end

  test "doc:patch with version mismatch returns current state", %{socket: socket, code: code} do
    CollabMd.Room.update_document(code, "v1", "setup")
    CollabMd.Room.update_document(code, "v2", "setup")

    ops = [%{"op" => "delete", "content" => "v1"}, %{"op" => "insert", "content" => "patched"}]
    ref = push(socket, "doc:patch", %{"ops" => ops, "author" => "alice", "base_version" => 1})

    assert_reply ref, :ok, %{
      "version_mismatch" => true,
      "document" => "v2",
      "version" => 2
    }
  end

  test "doc:patch with invalid patch content returns error", %{socket: socket, code: code} do
    CollabMd.Room.update_document(code, "actual content\n", "setup")

    ops = [%{"op" => "equal", "content" => "wrong content\n"}]
    ref = push(socket, "doc:patch", %{"ops" => ops, "author" => "alice", "base_version" => 1})

    assert_reply ref, :error, %{"reason" => _}
  end

  test "doc:patch updates server document state", %{socket: socket, code: code} do
    CollabMd.Room.update_document(code, "old\n", "setup")

    ops = [%{"op" => "delete", "content" => "old\n"}, %{"op" => "insert", "content" => "new\n"}]
    ref = push(socket, "doc:patch", %{"ops" => ops, "author" => "alice", "base_version" => 1})
    assert_reply ref, :ok, _

    assert {:ok, "new\n"} = CollabMd.Room.get_document(code)
  end

  test "joining nonexistent room returns error" do
    assert {:error, %{reason: "room_not_found"}} =
             CollabMdWeb.UserSocket
             |> socket("user", %{})
             |> subscribe_and_join(CollabMdWeb.RoomChannel, "room:nonexistent", %{
               "username" => "bob"
             })
  end
end
