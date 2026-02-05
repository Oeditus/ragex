defmodule Ragex.Retrieval.CrossLanguage do
  @moduledoc """
  Cross-language semantic search using MetaAST equivalence.

  Enables finding semantically equivalent code constructs across different
  programming languages by comparing their MetaAST representations.

  ## Examples

      # Find map operations in any language
      CrossLanguage.search_equivalent(:elixir, "Enum.map", [:python, :javascript])
      # => [python list comprehension, javascript Array.map]

      # Find all implementations of a pattern
      CrossLanguage.find_all_implementations({:collection_op, :map, _, _})
      # => Results from all languages with map/transform operations
  """

  alias Ragex.Graph.Store
  alias Ragex.Retrieval.MetaASTRanker

  require Logger

  @doc """
  Search for semantically equivalent constructs across languages.

  Given a source construct in one language, finds equivalent constructs
  in other languages using MetaAST comparison.

  ## Parameters

  - `source_language` - The source language (`:elixir`, `:python`, etc.)
  - `source_construct` - The construct to search for (function name, node_id, or MetaAST)
  - `target_languages` - List of languages to search in (default: all supported)
  - `opts` - Search options

  ## Options

  - `:limit` - Maximum results per language (default: 5)
  - `:threshold` - Semantic similarity threshold (default: 0.6)
  - `:include_source` - Include source language results (default: false)
  - `:strict_equivalence` - Require exact AST match (default: false)

  ## Returns

  `{:ok, results}` where results is a map: `%{language => [result]}`

  ## Examples

      # Find Python equivalents of Elixir Enum.map
      CrossLanguage.search_equivalent(:elixir, {:Enum, :map, 2}, [:python, :javascript])
      {:ok, %{
        python: [%{node_id: "list_comprehension", score: 0.95, ...}],
        javascript: [%{node_id: "Array.map", score: 0.92, ...}]
      }}
  """
  @spec search_equivalent(atom(), term(), list(atom()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def search_equivalent(source_language, source_construct, target_languages \\ [], opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    threshold = Keyword.get(opts, :threshold, 0.6)
    include_source = Keyword.get(opts, :include_source, false)
    strict_equivalence = Keyword.get(opts, :strict_equivalence, false)

    # Get source node
    with {:ok, source_node} <- resolve_source_node(source_language, source_construct),
         {:ok, source_meta_ast} <- get_node_meta_ast(source_node) do
      # Determine target languages
      search_languages =
        if Enum.empty?(target_languages) do
          get_all_languages()
        else
          target_languages
        end

      search_languages =
        if include_source do
          search_languages
        else
          Enum.reject(search_languages, &(&1 == source_language))
        end

      # Search each language for equivalents
      results =
        search_languages
        |> Enum.map(fn language ->
          language_results =
            find_equivalents_in_language(
              source_meta_ast,
              language,
              limit,
              threshold,
              strict_equivalence
            )

          {language, language_results}
        end)
        |> Enum.into(%{})

      {:ok, results}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Find all implementations of a MetaAST pattern across languages.

  Searches the entire codebase for nodes matching the given MetaAST pattern,
  regardless of language.

  ## Parameters

  - `meta_ast_pattern` - The MetaAST pattern to search for
  - `opts` - Search options

  ## Options

  - `:limit` - Maximum results (default: 20)
  - `:threshold` - Semantic similarity threshold for fuzzy matching (default: 0.7)
  - `:languages` - Filter by languages (default: all)
  - `:node_type` - Filter by node type (default: all)

  ## Examples

      # Find all map/transform operations
      pattern = {:collection_op, :map, :_, :_}
      CrossLanguage.find_all_implementations(pattern)
  """
  @spec find_all_implementations(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def find_all_implementations(meta_ast_pattern, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    languages = Keyword.get(opts, :languages, get_all_languages())
    node_type = Keyword.get(opts, :node_type)

    # Get all nodes that might match
    all_nodes = Store.list_nodes(node_type, limit * 10)

    # Filter by language and MetaAST match
    matching_nodes =
      all_nodes
      |> Enum.filter(fn node ->
        with node_language <- get_node_language(node),
             true <- node_language in languages,
             {:ok, meta_ast} <- get_node_meta_ast(node),
             do: meta_ast_matches_pattern?(meta_ast, meta_ast_pattern),
             else: (_ -> false)
      end)
      |> Enum.take(limit)
      |> Enum.map(&node_to_result/1)

    {:ok, matching_nodes}
  end

  @doc """
  Group results by their semantic equivalence classes.

  Returns groups of results that are semantically equivalent to each other.

  ## Examples

      results = [elixir_map, python_comprehension, js_map, elixir_filter, python_filter]

      CrossLanguage.group_by_equivalence(results)
      # => [
      #   [elixir_map, python_comprehension, js_map],  # map operations
      #   [elixir_filter, python_filter]               # filter operations
      # ]
  """
  @spec group_by_equivalence([map()]) :: [[map()]]
  def group_by_equivalence(results) do
    # Build equivalence groups using union-find approach
    groups = []

    Enum.reduce(results, groups, fn result, acc_groups ->
      # Find existing group this result belongs to
      matching_group_idx =
        Enum.find_index(acc_groups, fn group ->
          Enum.any?(group, fn member ->
            MetaASTRanker.semantically_equivalent?(result, member)
          end)
        end)

      case matching_group_idx do
        nil ->
          # Start new group
          [[result] | acc_groups]

        idx ->
          # Add to existing group
          List.update_at(acc_groups, idx, fn group -> [result | group] end)
      end
    end)
  end

  @doc """
  Suggest cross-language alternatives for a code snippet.

  Given a code construct, suggests equivalent implementations in other languages.

  ## Examples

      source = %{
        language: :python,
        code: "[x * 2 for x in items]",
        meta_ast: {:collection_op, :map, ...}
      }

      CrossLanguage.suggest_alternatives(source, [:elixir, :javascript])
      # => [
      #   %{language: :elixir, suggestion: "Enum.map(items, &(&1 * 2))", ...},
      #   %{language: :javascript, suggestion: "items.map(x => x * 2)", ...}
      # ]
  """
  @spec suggest_alternatives(map(), list(atom()), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def suggest_alternatives(source, target_languages, opts \\ []) do
    source_language = Map.get(source, :language)

    with {:ok, source_meta_ast} <-
           get_meta_ast_from_map(source),
         {:ok, equivalents} <-
           search_by_meta_ast(source_meta_ast, target_languages, opts) do
      suggestions =
        equivalents
        |> Enum.flat_map(fn {language, results} ->
          Enum.map(results, fn result ->
            %{
              language: language,
              node_id: result.node_id,
              score: result[:score] || 0.0,
              code_sample: extract_code_sample(result),
              explanation: generate_explanation(source_language, language, source_meta_ast)
            }
          end)
        end)

      {:ok, suggestions}
    end
  end

  # Private functions

  defp resolve_source_node(_language, {module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    case Store.find_node(:function, {module, function, arity}) do
      nil -> {:error, "Function not found: #{module}.#{function}/#{arity}"}
      node -> {:ok, node}
    end
  end

  defp resolve_source_node(_language, node_id) when is_tuple(node_id) do
    # Assume it's already a node_id
    case Store.find_node(:function, node_id) do
      nil -> {:error, "Node not found: #{inspect(node_id)}"}
      node -> {:ok, node}
    end
  end

  defp resolve_source_node(_language, meta_ast) when is_tuple(meta_ast) do
    # Assume it's a MetaAST pattern
    {:ok, %{meta_ast: meta_ast}}
  end

  defp resolve_source_node(_language, other) do
    {:error, "Invalid source construct: #{inspect(other)}"}
  end

  defp get_node_meta_ast(%{meta_ast: meta_ast}) when not is_nil(meta_ast),
    do: {:ok, meta_ast}

  defp get_node_meta_ast(%{data: %{meta_ast: meta_ast}}) when not is_nil(meta_ast),
    do: {:ok, meta_ast}

  defp get_node_meta_ast(_node),
    do: {:error, "No MetaAST available for node"}

  defp get_meta_ast_from_map(%{meta_ast: meta_ast}) when not is_nil(meta_ast),
    do: {:ok, meta_ast}

  defp get_meta_ast_from_map(_), do: {:error, "No MetaAST in source"}

  defp find_equivalents_in_language(source_meta_ast, language, limit, threshold, strict) do
    # Get all nodes for this language
    language_nodes = get_nodes_by_language(language, limit * 5)

    language_nodes
    |> Enum.map(fn node ->
      case get_node_meta_ast(node) do
        {:ok, node_meta_ast} ->
          if strict do
            if meta_ast_equals?(source_meta_ast, node_meta_ast) do
              {node, 1.0}
            else
              nil
            end
          else
            score = meta_ast_similarity(source_meta_ast, node_meta_ast)

            if score >= threshold do
              {node, score}
            else
              nil
            end
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_node, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {node, score} ->
      node_to_result(node, score)
    end)
  end

  defp search_by_meta_ast(meta_ast, target_languages, opts) do
    limit = Keyword.get(opts, :limit, 5)
    threshold = Keyword.get(opts, :threshold, 0.6)

    results =
      target_languages
      |> Enum.map(fn language ->
        language_results =
          find_equivalents_in_language(meta_ast, language, limit, threshold, false)

        {language, language_results}
      end)
      |> Enum.into(%{})

    {:ok, results}
  end

  defp get_all_languages do
    # Extract unique languages from all nodes
    Store.list_nodes(nil, 10_000)
    |> Enum.map(&get_node_language/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp get_node_language(%{data: %{language: lang}}), do: lang
  defp get_node_language(%{language: lang}), do: lang

  defp get_node_language(%{data: %{file: file}}) when is_binary(file) do
    language_from_file(file)
  end

  defp get_node_language(%{file: file}) when is_binary(file) do
    language_from_file(file)
  end

  defp get_node_language(_), do: nil

  defp language_from_file(file) do
    cond do
      String.ends_with?(file, [".ex", ".exs"]) -> :elixir
      String.ends_with?(file, [".erl", ".hrl"]) -> :erlang
      String.ends_with?(file, ".py") -> :python
      String.ends_with?(file, [".js", ".jsx", ".ts", ".tsx"]) -> :javascript
      true -> nil
    end
  end

  defp get_nodes_by_language(language, limit) do
    Store.list_nodes(nil, limit * 2)
    |> Enum.filter(fn node ->
      get_node_language(node) == language
    end)
    |> Enum.take(limit)
  end

  defp meta_ast_matches_pattern?(meta_ast, pattern) do
    # Pattern matching for new 3-tuple format: {type, meta, children}
    case pattern do
      :_ ->
        true

      ^meta_ast ->
        true

      # Match by type only: {tag, :_, :_}
      {tag, :_, :_} when is_tuple(meta_ast) and tuple_size(meta_ast) == 3 ->
        elem(meta_ast, 0) == tag

      # Match by type and metadata key (for op_type, loop_type, etc.)
      # Pattern: {tag, %{key => value}, :_}
      {tag, meta_pattern, :_}
      when is_tuple(meta_ast) and tuple_size(meta_ast) == 3 and is_map(meta_pattern) ->
        {ast_tag, ast_meta, _} = meta_ast

        ast_tag == tag and
          Enum.all?(meta_pattern, fn {key, value} ->
            Keyword.get(ast_meta, key) == value
          end)

      # Legacy 4-tuple patterns (for backward compatibility)
      {tag, :_, :_, :_} when is_tuple(meta_ast) ->
        elem(meta_ast, 0) == tag

      {tag, op, :_, :_} when is_tuple(meta_ast) and tuple_size(meta_ast) > 1 ->
        elem(meta_ast, 0) == tag and elem(meta_ast, 1) == op

      _ ->
        meta_ast == pattern
    end
  end

  defp meta_ast_equals?(ast1, ast2), do: ast1 == ast2

  defp meta_ast_similarity(ast1, ast2) do
    # Compute structural similarity
    cond do
      ast1 == ast2 ->
        1.0

      is_tuple(ast1) and is_tuple(ast2) ->
        # Same tag?
        if elem(ast1, 0) == elem(ast2, 0) do
          # Count matching elements
          size1 = tuple_size(ast1)
          size2 = tuple_size(ast2)

          if size1 == size2 do
            # Weighted similarity based on matching elements
            0.7 + 0.1 * min(size1, 3)
          else
            0.7
          end
        else
          0.3
        end

      true ->
        0.0
    end
  end

  defp node_to_result(node, score \\ 0.0) do
    %{
      node_type: node.type,
      node_id: node.id,
      score: score,
      language: get_node_language(node),
      meta_ast: get_node_meta_ast_value(node),
      text: node[:text] || ""
    }
  end

  defp get_node_meta_ast_value(%{meta_ast: ast}), do: ast
  defp get_node_meta_ast_value(%{data: %{meta_ast: ast}}), do: ast
  defp get_node_meta_ast_value(_), do: nil

  defp extract_code_sample(%{text: text}) when is_binary(text) and byte_size(text) > 0 do
    # Return first 200 chars
    String.slice(text, 0, 200)
  end

  defp extract_code_sample(%{code: code}) when is_binary(code), do: code
  defp extract_code_sample(_), do: ""

  defp generate_explanation(source_lang, target_lang, meta_ast) do
    construct_name = extract_construct_name(meta_ast)
    "#{construct_name} in #{source_lang} is equivalent to this #{target_lang} implementation"
  end

  # New 3-tuple format: {type, keyword_meta, children}
  defp extract_construct_name({:collection_op, meta, _children}) when is_list(meta) do
    op = Keyword.get(meta, :op_type, :unknown)
    "#{op} operation"
  end

  defp extract_construct_name({:loop, meta, _children}) when is_list(meta) do
    loop_type = Keyword.get(meta, :loop_type, :unknown)
    "#{loop_type} loop"
  end

  defp extract_construct_name({:lambda, _meta, _body}), do: "lambda function"
  defp extract_construct_name({:pattern_match, _meta, _children}), do: "pattern match"
  defp extract_construct_name({:conditional, _meta, _children}), do: "conditional"

  defp extract_construct_name({:function_def, meta, _body}) when is_list(meta) do
    name = Keyword.get(meta, :name, "unknown")
    "function #{name}"
  end

  defp extract_construct_name({:function_call, meta, _args}) when is_list(meta) do
    name = Keyword.get(meta, :name, "unknown")
    "call to #{name}"
  end

  defp extract_construct_name({:binary_op, meta, _children}) when is_list(meta) do
    operator = Keyword.get(meta, :operator, :unknown)
    "#{operator} operation"
  end

  defp extract_construct_name({:container, meta, _body}) when is_list(meta) do
    container_type = Keyword.get(meta, :container_type, :unknown)
    name = Keyword.get(meta, :name, "unknown")
    "#{container_type} #{name}"
  end

  defp extract_construct_name(_), do: "construct"
end
