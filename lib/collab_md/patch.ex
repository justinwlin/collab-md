defmodule CollabMd.Patch do
  @moduledoc """
  Applies diff patches to document strings.

  Patch format: a list of operations, each a map with:
  - "op" => "equal" | "delete" | "insert"
  - "content" => string

  Equal/delete ops are verified against the current document position.
  Insert ops add new content. The result is the patched document.
  """

  @spec apply(String.t(), list(map())) :: {:ok, String.t()} | {:error, atom()}
  def apply(document, ops) when is_binary(document) and is_list(ops) do
    apply_ops(document, ops, [])
  end

  defp apply_ops(<<>>, [], acc) do
    {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  end

  defp apply_ops(remaining, [], _acc) when byte_size(remaining) > 0 do
    {:error, :leftover_content}
  end

  defp apply_ops(remaining, [%{"op" => "insert", "content" => content} | rest], acc) do
    apply_ops(remaining, rest, [content | acc])
  end

  defp apply_ops(remaining, [%{"op" => op, "content" => content} | rest], acc)
       when op in ["equal", "delete"] do
    size = byte_size(content)

    if byte_size(remaining) >= size do
      <<prefix::binary-size(size), tail::binary>> = remaining

      if prefix == content do
        new_acc = if op == "equal", do: [content | acc], else: acc
        apply_ops(tail, rest, new_acc)
      else
        {:error, :mismatch}
      end
    else
      {:error, :mismatch}
    end
  end

  defp apply_ops(_remaining, [_invalid | _rest], _acc) do
    {:error, :invalid_op}
  end
end
