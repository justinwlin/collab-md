defmodule CollabMd.RoomSupervisorTest do
  use ExUnit.Case, async: false  # async: false because it uses global supervisor

  alias CollabMd.RoomSupervisor
  alias CollabMd.Room

  test "create_room returns a 6-char hex code" do
    {:ok, code} = RoomSupervisor.create_room()
    assert String.length(code) == 6
    assert Regex.match?(~r/^[a-f0-9]{6}$/, code)
  end

  test "created room is accessible via Room API" do
    {:ok, code} = RoomSupervisor.create_room()
    assert RoomSupervisor.room_exists?(code)
    assert {:ok, ""} = Room.get_document(code)
  end

  test "room_exists? returns false for nonexistent room" do
    refute RoomSupervisor.room_exists?("nope00")
  end
end
