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

  test "joining nonexistent room returns error" do
    assert {:error, %{reason: "room_not_found"}} =
             CollabMdWeb.UserSocket
             |> socket("user", %{})
             |> subscribe_and_join(CollabMdWeb.RoomChannel, "room:nonexistent", %{
               "username" => "bob"
             })
  end
end
