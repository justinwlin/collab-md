defmodule CollabMd.RoomTest do
  use ExUnit.Case, async: false

  alias CollabMd.Room

  setup do
    # Registry is started globally by the application supervision tree.
    code = "test#{System.unique_integer([:positive])}"
    start_supervised!({Room, %{code: code}})
    %{code: code}
  end

  describe "new room" do
    test "starts with an empty document", %{code: code} do
      assert {:ok, ""} = Room.get_document(code)
    end

    test "starts with no versions", %{code: code} do
      assert {:ok, []} = Room.get_versions(code)
    end

    test "starts with no users", %{code: code} do
      assert {:ok, %{users: users}} = Room.status(code)
      assert users == []
    end

    test "status reports version 0 initially", %{code: code} do
      assert {:ok, %{version: 0}} = Room.status(code)
    end
  end

  describe "update_document/3" do
    test "saves the new document content", %{code: code} do
      {:ok, _} = Room.update_document(code, "# Hello", "alice")
      assert {:ok, "# Hello"} = Room.get_document(code)
    end

    test "returns the new version number", %{code: code} do
      assert {:ok, 1} = Room.update_document(code, "first", "alice")
      assert {:ok, 2} = Room.update_document(code, "second", "bob")
    end

    test "creates a version snapshot of the previous content", %{code: code} do
      Room.update_document(code, "first", "alice")
      {:ok, versions} = Room.get_versions(code)
      assert length(versions) == 1
      [v1] = versions
      assert v1.number == 1
      assert v1.author == "alice"
      assert %DateTime{} = v1.timestamp
    end

    test "multiple updates create version history in correct order (newest first)", %{code: code} do
      Room.update_document(code, "first", "alice")
      Room.update_document(code, "second", "bob")
      Room.update_document(code, "third", "charlie")
      {:ok, versions} = Room.get_versions(code)
      assert length(versions) == 3
      [v3, v2, v1] = versions
      assert v3.number == 3
      assert v2.number == 2
      assert v1.number == 1
    end

    test "get_versions returns metadata without content", %{code: code} do
      Room.update_document(code, "some content", "alice")
      {:ok, [version]} = Room.get_versions(code)
      refute Map.has_key?(version, :content)
    end
  end

  describe "restore_version/2" do
    test "restores the document to a previous version's content", %{code: code} do
      Room.update_document(code, "version one content", "alice")
      Room.update_document(code, "version two content", "bob")
      {:ok, restored} = Room.restore_version(code, 1)
      assert restored == "version one content"
      assert {:ok, "version one content"} = Room.get_document(code)
    end

    test "restoring creates a new version snapshot", %{code: code} do
      Room.update_document(code, "v1", "alice")
      Room.update_document(code, "v2", "bob")
      Room.restore_version(code, 1)
      {:ok, versions} = Room.get_versions(code)
      assert length(versions) == 3
    end

    test "returns error for nonexistent version number", %{code: code} do
      assert {:error, :not_found} = Room.restore_version(code, 99)
    end

    test "returns error for version 0 (no versions exist)", %{code: code} do
      assert {:error, :not_found} = Room.restore_version(code, 0)
    end
  end

  describe "join/2 and leave/2" do
    test "join adds the user to the room", %{code: code} do
      :ok = Room.join(code, "alice")
      {:ok, %{users: users}} = Room.status(code)
      assert "alice" in users
    end

    test "multiple users can join", %{code: code} do
      Room.join(code, "alice")
      Room.join(code, "bob")
      {:ok, %{users: users}} = Room.status(code)
      assert "alice" in users
      assert "bob" in users
    end

    test "join is idempotent (duplicate joins don't create duplicate entries)", %{code: code} do
      Room.join(code, "alice")
      Room.join(code, "alice")
      {:ok, %{users: users}} = Room.status(code)
      assert Enum.count(users, &(&1 == "alice")) == 1
    end

    test "leave removes the user from the room", %{code: code} do
      Room.join(code, "alice")
      Room.join(code, "bob")
      Room.leave(code, "alice")
      # Give the cast time to process
      :timer.sleep(10)
      {:ok, %{users: users}} = Room.status(code)
      refute "alice" in users
      assert "bob" in users
    end

    test "leaving when not in room is a no-op", %{code: code} do
      Room.leave(code, "ghost")
      :timer.sleep(10)
      {:ok, %{users: users}} = Room.status(code)
      refute "ghost" in users
    end
  end

  describe "status/1" do
    test "returns created_at timestamp", %{code: code} do
      {:ok, %{created_at: created_at}} = Room.status(code)
      assert %DateTime{} = created_at
    end

    test "version count increments with updates", %{code: code} do
      {:ok, %{version: 0}} = Room.status(code)
      Room.update_document(code, "hello", "alice")
      {:ok, %{version: 1}} = Room.status(code)
      Room.update_document(code, "world", "bob")
      {:ok, %{version: 2}} = Room.status(code)
    end
  end
end
