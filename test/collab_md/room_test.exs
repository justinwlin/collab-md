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

  describe "apply_patch/4" do
    test "applies a valid patch and returns new version", %{code: code} do
      Room.update_document(code, "line 1\nline 2\n", "setup")

      ops = [
        %{"op" => "equal", "content" => "line 1\n"},
        %{"op" => "delete", "content" => "line 2\n"},
        %{"op" => "insert", "content" => "modified line 2\n"}
      ]

      assert {:ok, 2} = Room.apply_patch(code, ops, "alice", 1)
      assert {:ok, "line 1\nmodified line 2\n"} = Room.get_document(code)
    end

    test "creates a version snapshot", %{code: code} do
      Room.update_document(code, "original\n", "setup")
      ops = [
        %{"op" => "delete", "content" => "original\n"},
        %{"op" => "insert", "content" => "patched\n"}
      ]

      Room.apply_patch(code, ops, "alice", 1)
      {:ok, versions} = Room.get_versions(code)
      assert length(versions) == 2
      [latest | _] = versions
      assert latest.number == 2
      assert latest.author == "alice"
    end

    test "rejects patch when base_version mismatches", %{code: code} do
      Room.update_document(code, "v1", "setup")
      Room.update_document(code, "v2", "setup")

      ops = [%{"op" => "delete", "content" => "v1"}, %{"op" => "insert", "content" => "v1-patched"}]

      assert {:error, :version_mismatch, "v2", 2} = Room.apply_patch(code, ops, "alice", 1)
    end

    test "version mismatch returns current document and version", %{code: code} do
      Room.update_document(code, "current content", "setup")

      ops = [%{"op" => "equal", "content" => "stale"}]
      {:error, :version_mismatch, doc, version} = Room.apply_patch(code, ops, "alice", 0)

      assert doc == "current content"
      assert version == 1
    end

    test "rejects patch with mismatched content", %{code: code} do
      Room.update_document(code, "actual content\n", "setup")

      ops = [%{"op" => "equal", "content" => "wrong content\n"}]
      assert {:error, :mismatch} = Room.apply_patch(code, ops, "alice", 1)
    end

    test "sequential patches increment version correctly", %{code: code} do
      Room.update_document(code, "v0\n", "setup")

      ops1 = [%{"op" => "equal", "content" => "v0\n"}, %{"op" => "insert", "content" => "A\n"}]
      assert {:ok, 2} = Room.apply_patch(code, ops1, "alice", 1)

      ops2 = [%{"op" => "equal", "content" => "v0\nA\n"}, %{"op" => "insert", "content" => "B\n"}]
      assert {:ok, 3} = Room.apply_patch(code, ops2, "alice", 2)

      assert {:ok, "v0\nA\nB\n"} = Room.get_document(code)
    end
  end

  describe "apply_crdt_update/4" do
    test "stores CRDT update and updates document text", %{code: code} do
      {:ok, version} = Room.apply_crdt_update(code, <<1, 2, 3>>, "new text", "alice")
      assert version == 1
      assert {:ok, "new text"} = Room.get_document(code)
    end

    test "accumulates CRDT updates", %{code: code} do
      Room.apply_crdt_update(code, <<1>>, "v1", "alice")
      Room.apply_crdt_update(code, <<2>>, "v2", "alice")
      {:ok, updates} = Room.get_crdt_state(code)
      assert length(updates) == 2
      assert updates == [<<1>>, <<2>>]
    end

    test "creates version snapshots", %{code: code} do
      Room.apply_crdt_update(code, <<1>>, "v1", "alice")
      Room.apply_crdt_update(code, <<2>>, "v2", "bob")
      {:ok, versions} = Room.get_versions(code)
      assert length(versions) == 2
    end

    test "plain update_document clears CRDT state", %{code: code} do
      Room.apply_crdt_update(code, <<1>>, "crdt text", "alice")
      {:ok, updates_before} = Room.get_crdt_state(code)
      assert length(updates_before) == 1

      Room.update_document(code, "plain update", "bob")
      {:ok, updates_after} = Room.get_crdt_state(code)
      assert updates_after == []
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
