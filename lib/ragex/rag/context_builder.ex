defmodule Ragex.RAG.ContextBuilder do
  @moduledoc """
  Formats retrieved code for AI consumption.

  Supports multiple output formats:
  - `:text` - Markdown-formatted context (default)
  - `:json` - Structured JSON with code metadata
  - `:ast` - JSON with MetaAST data, purity, and complexity

  ## Options

  - `:format` - Output format: `:text`, `:json`, or `:ast` (default: `:text`)
  - `:include_code` - Include full code snippets (default: true)
  - `:max_context_length` - Max context size in characters (default: 8000)
  """

  # characters
  @max_context_length 8000

  @doc """
  Build context from retrieval results in the specified format.

  ## Parameters

  - `results` - List of retrieval result maps
  - `opts` - Keyword list of options

  ## Returns

  - `{:ok, context}` where context is a string (text/json/ast encoded)
  """
  @spec build_context([map()], keyword()) :: {:ok, String.t()}
  def build_context(results, opts \\ []) do
    case Keyword.get(opts, :format, :text) do
      :json -> build_json_context(results, opts)
      :ast -> build_ast_context(results, opts)
      _text -> build_text_context(results, opts)
    end
  end

  # Private functions

  # Text format (original markdown)
  defp build_text_context(results, opts) do
    include_code = Keyword.get(opts, :include_code, true)
    max_length = Keyword.get(opts, :max_context_length, @max_context_length)

    context =
      results
      |> Enum.map_join("\n\n---\n\n", &format_text_result(&1, include_code))
      |> truncate_if_needed(max_length)

    {:ok, context}
  end

  # JSON format (structured metadata without AST)
  defp build_json_context(results, opts) do
    include_code = Keyword.get(opts, :include_code, true)
    max_length = Keyword.get(opts, :max_context_length, @max_context_length)

    entries = Enum.map(results, &format_json_result(&1, include_code))

    context =
      %{results: entries, total: length(entries)}
      |> Jason.encode!()
      |> truncate_if_needed(max_length)

    {:ok, context}
  end

  # AST format (includes MetaAST, purity, complexity)
  defp build_ast_context(results, opts) do
    include_code = Keyword.get(opts, :include_code, true)
    max_length = Keyword.get(opts, :max_context_length, @max_context_length)

    entries = Enum.map(results, &format_ast_result(&1, include_code))

    context =
      %{results: entries, total: length(entries), format: "ast"}
      |> Jason.encode!()
      |> truncate_if_needed(max_length)

    {:ok, context}
  end

  # Text result formatter (original)
  defp format_text_result(result, include_code) do
    """
    ## #{result[:node_id] || "Unknown"}

    **File**: #{result[:file] || "unknown"}
    **Line**: #{result[:line] || "N/A"}
    **Score**: #{Float.round(result[:score] || 0.0, 3)}
    #{if result[:complexity], do: "**Complexity**: #{inspect(result[:complexity])}", else: ""}
    #{if result[:purity], do: "**Purity**: #{if result[:purity].pure?, do: "Pure", else: "Impure"}", else: ""}

    #{if include_code and result[:code] do
      """
      ```#{result[:language] || ""}
      #{result[:code]}
      ```
      """
    else
      result[:text] || result[:doc] || "No description available"
    end}
    """
  end

  # JSON result formatter (structured, no AST)
  defp format_json_result(result, include_code) do
    base = %{
      node_id: format_node_id(result[:node_id]),
      file: result[:file],
      line: result[:line],
      score: safe_round(result[:score]),
      language: result[:language],
      node_type: to_string(result[:node_type] || "unknown")
    }

    base =
      if include_code and result[:code] do
        Map.put(base, :code, result[:code])
      else
        Map.put(base, :description, result[:text] || result[:doc] || "No description")
      end

    base
  end

  # AST result formatter (full metadata including MetaAST)
  defp format_ast_result(result, include_code) do
    base = format_json_result(result, include_code)

    base
    |> maybe_put(:meta_ast, serialize_meta_ast(result[:meta_ast]))
    |> maybe_put(:meta_ast_metadata, serialize_meta_ast_metadata(result[:meta_ast_metadata]))
    |> maybe_put(:purity, serialize_purity(result[:purity]))
    |> maybe_put(:complexity, result[:complexity])
    |> maybe_put(:boosted_score, result[:boosted_score])
    |> maybe_put(:metaast_boost, result[:metaast_boost])
    |> maybe_put(:ranking_intent, safe_to_string(result[:ranking_intent]))
  end

  # Helpers

  defp truncate_if_needed(context, max_length) when byte_size(context) > max_length do
    truncated = String.slice(context, 0, max_length)
    truncated <> "\n\n... (context truncated)"
  end

  defp truncate_if_needed(context, _max_length), do: context

  defp format_node_id(nil), do: nil
  defp format_node_id(id) when is_binary(id), do: id
  defp format_node_id(id) when is_atom(id), do: Atom.to_string(id)

  defp format_node_id({module, name, arity}) do
    "#{inspect(module)}.#{name}/#{arity}"
  end

  defp format_node_id(id), do: inspect(id)

  defp safe_round(nil), do: 0.0
  defp safe_round(f) when is_float(f), do: Float.round(f, 3)
  defp safe_round(n), do: n

  defp safe_to_string(nil), do: nil
  defp safe_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_to_string(other), do: to_string(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # MetaAST serialization (tuples -> JSON-safe maps/lists)
  defp serialize_meta_ast(nil), do: nil

  defp serialize_meta_ast({type, meta, children}) when is_atom(type) and is_list(meta) do
    %{
      type: Atom.to_string(type),
      meta: serialize_keyword(meta),
      children: serialize_meta_ast(children)
    }
  end

  defp serialize_meta_ast(list) when is_list(list) do
    Enum.map(list, &serialize_meta_ast/1)
  end

  defp serialize_meta_ast(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp serialize_meta_ast(other), do: other

  defp serialize_keyword(kw) when is_list(kw) do
    Map.new(kw, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), serialize_meta_ast(v)}
      {k, v} -> {to_string(k), serialize_meta_ast(v)}
    end)
  end

  defp serialize_keyword(other), do: other

  defp serialize_meta_ast_metadata(nil), do: nil

  defp serialize_meta_ast_metadata(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), serialize_value(v)}
      {k, v} -> {to_string(k), serialize_value(v)}
    end)
  end

  defp serialize_meta_ast_metadata(_), do: nil

  defp serialize_purity(nil), do: nil

  defp serialize_purity(purity) when is_map(purity) do
    %{
      pure: Map.get(purity, :pure?, Map.get(purity, :pure, false)),
      side_effects: Map.get(purity, :side_effects, [])
    }
  end

  defp serialize_purity(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp serialize_purity(_), do: nil

  defp serialize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_value(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&serialize_value/1)
  defp serialize_value(v) when is_list(v), do: Enum.map(v, &serialize_value/1)

  defp serialize_value(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {to_string(k), serialize_value(val)} end)
  end

  defp serialize_value(v), do: v
end
