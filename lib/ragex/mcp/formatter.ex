defmodule Ragex.MCP.Formatter do
  @moduledoc """
  Centralized response formatting for MCP tool results.

  Sits between `Tools.call_tool/2` and the JSON serializer in
  `Server.handle_tools_call/2`. Every tool result passes through
  `format/3` which applies compaction, token budgeting, and smart
  suggestions based on the formatting options.

  ## Modes

  - `:compact` (default) -- truncates lists, strips verbose fields
    (docs, specs, long strings), and appends next-step suggestions.
  - `:verbose` -- passes the result through unchanged (current behavior).

  ## Token Budget

  When `max_tokens` is specified, the formatter estimates the JSON size
  of the result (~4 chars per token) and truncates to fit.

  ## Smart Suggestions

  In compact mode, the formatter appends `_suggestions` with actionable
  next-step hints based on the result shape and tool name.

  ## Usage

  The formatter is invoked automatically by `Server.handle_tools_call/2`.
  Tool handlers do not need to call it directly.

  Options are extracted from tool arguments:

  - `\"verbose\"` (boolean, default `false`) -- if true, skip compaction
  - `\"max_tokens\"` (integer, optional) -- token budget for the response
  """

  alias Ragex.MCP.Formattable

  @chars_per_token 4
  @default_max_items 10

  @doc """
  Format a tool result based on options.

  ## Parameters
  - `result` -- the raw result from `Tools.call_tool/2` (the value inside `{:ok, result}`)
  - `tool_name` -- string name of the tool that produced the result
  - `opts` -- formatting options:
    - `:verbose` -- boolean (default `false`)
    - `:max_tokens` -- integer token budget (optional)

  ## Returns
  The formatted result (same shape as input, but potentially compacted).
  """
  @spec format(term(), String.t(), keyword()) :: term()
  def format(result, tool_name, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    max_tokens = Keyword.get(opts, :max_tokens)

    if verbose do
      result
    else
      result
      |> compact(tool_name)
      |> apply_token_budget(max_tokens)
      |> maybe_add_suggestions(tool_name)
    end
  end

  @doc """
  Extract formatting options from MCP tool arguments.

  Pulls `verbose` and `max_tokens` from the arguments map,
  returning a keyword list suitable for `format/3`.
  """
  @spec extract_opts(map()) :: keyword()
  def extract_opts(arguments) when is_map(arguments) do
    opts = []

    opts =
      case Map.get(arguments, "verbose") do
        true -> Keyword.put(opts, :verbose, true)
        _ -> opts
      end

    opts =
      case Map.get(arguments, "max_tokens") do
        n when is_integer(n) and n > 0 -> Keyword.put(opts, :max_tokens, n)
        _ -> opts
      end

    opts
  end

  def extract_opts(_), do: []

  # ── Compaction ───────────────────────────────────────────────────────

  defp compact(result, tool_name) do
    Formattable.compact(result, tool_name: tool_name, max_items: @default_max_items)
  end

  # ── Token Budget ─────────────────────────────────────────────────────

  defp apply_token_budget(result, nil), do: result

  defp apply_token_budget(result, max_tokens) when is_map(result) do
    # Estimate current size
    estimated = estimate_tokens(result)

    if estimated <= max_tokens do
      result
    else
      # Progressively reduce max_items until we fit
      reduce_to_budget(result, max_tokens)
    end
  end

  defp apply_token_budget(result, _max_tokens), do: result

  defp reduce_to_budget(result, max_tokens) do
    # Try reducing list sizes: 10 -> 5 -> 3 -> 1
    Enum.reduce_while([5, 3, 1], result, fn max_items, _acc ->
      reduced = Formattable.compact(result, max_items: max_items)

      if estimate_tokens(reduced) <= max_tokens do
        {:halt, reduced}
      else
        {:cont, reduced}
      end
    end)
  end

  @doc """
  Estimate the number of tokens a value will consume when JSON-encoded.

  Uses ~4 characters per token as a rough heuristic.
  """
  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(value) do
    size = estimated_json_size(value)
    div(size, @chars_per_token)
  end

  defp estimated_json_size(value) when is_map(value) do
    # Each key-value pair: key + colon + value + comma
    Enum.reduce(value, 2, fn {k, v}, acc ->
      key_size = estimated_json_size(k)
      val_size = estimated_json_size(v)
      acc + key_size + val_size + 3
    end)
  end

  defp estimated_json_size(value) when is_list(value) do
    Enum.reduce(value, 2, fn item, acc ->
      acc + estimated_json_size(item) + 1
    end)
  end

  defp estimated_json_size(true), do: 4
  defp estimated_json_size(false), do: 5
  defp estimated_json_size(nil), do: 4
  defp estimated_json_size(value) when is_binary(value), do: byte_size(value) + 2
  defp estimated_json_size(value) when is_integer(value), do: length(Integer.digits(value))
  defp estimated_json_size(value) when is_float(value), do: 8
  defp estimated_json_size(value) when is_atom(value), do: byte_size(Atom.to_string(value)) + 2
  defp estimated_json_size(_), do: 10

  # ── Smart Suggestions ────────────────────────────────────────────────

  defp maybe_add_suggestions(result, tool_name) when is_map(result) do
    suggestions = suggest_next(result, tool_name)

    if suggestions != [] do
      Map.put(result, :_suggestions, suggestions)
    else
      result
    end
  end

  defp maybe_add_suggestions(result, _tool_name), do: result

  @doc """
  Generate next-step suggestions based on the result shape and tool name.

  Returns a list of actionable hint strings.
  """
  @spec suggest_next(map(), String.t()) :: [String.t()]
  def suggest_next(result, tool_name) do
    suggestions = []

    # Truncation hint
    suggestions =
      case Map.get(result, :truncated) do
        %{} = truncated when map_size(truncated) > 0 ->
          counts =
            Enum.map_join(truncated, ", ", fn {key, count} ->
              "#{count} more #{key}"
            end)

          ["#{counts} -- use verbose=true to see all" | suggestions]

        _ ->
          suggestions
      end

    # Tool-specific hints
    suggestions = suggestions ++ tool_hints(tool_name, result)

    Enum.reverse(suggestions)
  end

  defp tool_hints("semantic_search", %{results: results}) when is_list(results) do
    case results do
      [first | _] when is_map(first) ->
        node_id = Map.get(first, :node_id) || Map.get(first, "node_id")

        if node_id do
          ["Use find_callers for '#{node_id}' to see what depends on it"]
        else
          []
        end

      _ ->
        []
    end
  end

  defp tool_hints("hybrid_search", result), do: tool_hints("semantic_search", result)

  defp tool_hints("find_callers", %{target: target}) do
    ["Use analyze_impact(target: '#{target}') for full dependency analysis"]
  end

  defp tool_hints("query_graph", %{found: true, node: node}) do
    file = Map.get(node, :file)

    if file do
      ["Use git_blame(path: '#{file}') to see who wrote this code"]
    else
      []
    end
  end

  defp tool_hints("list_nodes", %{count: count, total_count: total}) when count < total do
    ["Showing #{count} of #{total} -- increase limit or add node_type filter"]
  end

  defp tool_hints("git_blame", %{file: file}) do
    ["Use git_history(path: '#{file}') to see full commit history"]
  end

  defp tool_hints("git_history", %{file: file, function: nil}) do
    ["Use git_blame(path: '#{file}') for per-line authorship"]
  end

  defp tool_hints("git_history", %{file: file, function: func}) when is_binary(func) do
    ["Use git_blame(path: '#{file}') for line-level detail"]
  end

  defp tool_hints("co_change_analysis", %{file: file}) do
    ["Use analyze_impact(target: '#{file}') to understand change risk"]
  end

  defp tool_hints("analyze_impact", %{}) do
    ["Use suggest_refactorings to get actionable improvement suggestions"]
  end

  defp tool_hints("find_dead_code", %{}) do
    ["Use git_history to check when dead code was last modified"]
  end

  defp tool_hints("analyze_quality", %{}) do
    ["Use find_complex_code to drill into high-complexity functions"]
  end

  defp tool_hints("graph_stats", %{}) do
    [
      "Use betweenness_centrality to find bottleneck functions",
      "Use detect_communities to discover architectural modules"
    ]
  end

  defp tool_hints(_tool_name, _result), do: []
end
