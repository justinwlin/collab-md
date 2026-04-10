defmodule CollabMd.PatchTest do
  use ExUnit.Case, async: true

  alias CollabMd.Patch

  describe "apply/2 with valid ops" do
    test "applies equal-only ops (no change)" do
      assert {:ok, "hello world"} =
               Patch.apply("hello world", [%{"op" => "equal", "content" => "hello world"}])
    end

    test "applies insert-only ops (empty to content)" do
      assert {:ok, "new content\n"} =
               Patch.apply("", [%{"op" => "insert", "content" => "new content\n"}])
    end

    test "applies delete-only ops (content to empty)" do
      assert {:ok, ""} =
               Patch.apply("old content\n", [%{"op" => "delete", "content" => "old content\n"}])
    end

    test "applies mixed equal, delete, insert ops" do
      ops = [
        %{"op" => "equal", "content" => "line 1\n"},
        %{"op" => "delete", "content" => "line 2\n"},
        %{"op" => "insert", "content" => "modified line 2\n"},
        %{"op" => "equal", "content" => "line 3\n"},
        %{"op" => "insert", "content" => "new line 4\n"}
      ]

      assert {:ok, "line 1\nmodified line 2\nline 3\nnew line 4\n"} =
               Patch.apply("line 1\nline 2\nline 3\n", ops)
    end

    test "handles empty ops on empty document" do
      assert {:ok, ""} = Patch.apply("", [])
    end

    test "handles unicode content" do
      ops = [
        %{"op" => "equal", "content" => "café "},
        %{"op" => "delete", "content" => "latte"},
        %{"op" => "insert", "content" => "mocha ☕"}
      ]

      assert {:ok, "café mocha ☕"} = Patch.apply("café latte", ops)
    end

    test "insert at beginning" do
      ops = [
        %{"op" => "insert", "content" => "header\n"},
        %{"op" => "equal", "content" => "body\n"}
      ]

      assert {:ok, "header\nbody\n"} = Patch.apply("body\n", ops)
    end

    test "delete from end" do
      ops = [
        %{"op" => "equal", "content" => "keep\n"},
        %{"op" => "delete", "content" => "remove\n"}
      ]

      assert {:ok, "keep\n"} = Patch.apply("keep\nremove\n", ops)
    end
  end

  describe "apply/2 with invalid ops" do
    test "returns :mismatch when equal content doesn't match" do
      ops = [%{"op" => "equal", "content" => "wrong content"}]
      assert {:error, :mismatch} = Patch.apply("actual content", ops)
    end

    test "returns :mismatch when delete content doesn't match" do
      ops = [%{"op" => "delete", "content" => "wrong content"}]
      assert {:error, :mismatch} = Patch.apply("actual content", ops)
    end

    test "returns :mismatch when equal extends beyond document" do
      ops = [%{"op" => "equal", "content" => "this is way too long"}]
      assert {:error, :mismatch} = Patch.apply("short", ops)
    end

    test "returns :leftover_content when ops end before document" do
      ops = [%{"op" => "equal", "content" => "partial"}]
      assert {:error, :leftover_content} = Patch.apply("partial and more", ops)
    end

    test "returns :invalid_op for unknown op type" do
      ops = [%{"op" => "unknown", "content" => "data"}]
      assert {:error, :invalid_op} = Patch.apply("data", ops)
    end

    test "returns :leftover_content for empty ops on non-empty doc" do
      assert {:error, :leftover_content} = Patch.apply("has content", [])
    end
  end
end
