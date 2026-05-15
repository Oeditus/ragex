defprotocol Ragex.MCP.Formattable do
  @moduledoc """
  Protocol for compacting MCP tool responses.

  Types that implement this protocol define how to produce a compact
  representation (signatures, locations, counts only) versus a verbose
  one (full detail -- the current default behavior).

  The formatter calls `compact/2` when `verbose: false` (the new default)
  and falls through to the raw value when `verbose: true`.

  ## Implementing for a new struct

      defimpl Ragex.MCP.Formattable, for: MyResult do
        def compact(result, opts) do
          %{summary: result.summary, count: result.count}
        end
      end
  """

  @doc """
  Produce a compact representation of the value.

  ## Options
  - `:max_items` -- truncate lists to this many items
  - `:tool_name` -- the tool that produced this result (for context-aware compaction)
  """
  @spec compact(t, keyword()) :: term()
  def compact(value, opts)
end

# ── Default implementations ──────────────────────────────────────────

defimpl Ragex.MCP.Formattable, for: Map do
  @compactable_list_keys [
    :results,
    :nodes,
    :callers,
    :commits,
    :blame,
    :co_changes,
    :paths,
    :top_nodes,
    :top_by_pagerank,
    :top_by_degree,
    :communities,
    :backups,
    :providers,
    :by_operation,
    :by_language
  ]

  @strip_in_compact [
    :message,
    :body,
    :description,
    :code_sample,
    :text,
    :content,
    :explanation,
    :suggestions,
    :response
  ]

  def compact(map, opts) do
    max_items = Keyword.get(opts, :max_items, 10)

    map
    |> truncate_lists(max_items)
    |> strip_verbose_fields()
    |> compact_nested_items(max_items)
  end

  defp truncate_lists(map, max_items) do
    Enum.reduce(@compactable_list_keys, map, fn key, acc ->
      case Map.get(acc, key) do
        list when is_list(list) and length(list) > max_items ->
          truncated = Enum.take(list, max_items)
          remaining = length(list) - max_items

          acc
          |> Map.put(key, truncated)
          |> Map.put(:truncated, %{key => remaining})

        _ ->
          acc
      end
    end)
  end

  defp strip_verbose_fields(map) do
    Enum.reduce(@strip_in_compact, map, fn key, acc ->
      case Map.get(acc, key) do
        val when is_binary(val) and byte_size(val) > 200 ->
          Map.put(acc, key, String.slice(val, 0, 200) <> "...")

        _ ->
          acc
      end
    end)
  end

  defp compact_nested_items(map, _max_items) do
    Enum.reduce(@compactable_list_keys, map, fn key, acc ->
      case Map.get(acc, key) do
        list when is_list(list) ->
          Map.put(acc, key, Enum.map(list, &compact_single_item/1))

        _ ->
          acc
      end
    end)
  end

  defp compact_single_item(item) when is_map(item) do
    # Strip verbose fields from nested items
    item
    |> Map.drop([:doc, :moduledoc, :specs, :body, :description])
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_binary(v) and byte_size(v) > 150 ->
        Map.put(acc, k, String.slice(v, 0, 150) <> "...")

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  defp compact_single_item(item), do: item
end

defimpl Ragex.MCP.Formattable, for: List do
  def compact(list, opts) do
    max_items = Keyword.get(opts, :max_items, 10)

    if length(list) > max_items do
      truncated = Enum.take(list, max_items)
      remaining = length(list) - max_items
      %{items: truncated, truncated: remaining, total: length(list)}
    else
      list
    end
  end
end

# Passthrough for types that don't need compaction
defimpl Ragex.MCP.Formattable, for: BitString do
  def compact(str, _opts), do: str
end

defimpl Ragex.MCP.Formattable, for: Atom do
  def compact(atom, _opts), do: atom
end

defimpl Ragex.MCP.Formattable, for: Integer do
  def compact(int, _opts), do: int
end

defimpl Ragex.MCP.Formattable, for: Float do
  def compact(float, _opts), do: float
end
