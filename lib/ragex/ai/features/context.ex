defmodule Ragex.AI.Features.Context do
  @moduledoc """
  Context building helpers for AI-enhanced features.

  Provides utilities to build rich context from the knowledge graph and
  embeddings for AI prompts. This ensures AI responses are grounded in
  actual codebase data.

  ## Usage

      alias Ragex.AI.Features.Context

      # Build context for validation error
      context = Context.for_validation_error(error, file_path, surrounding_code)

      # Build context for refactoring preview
      context = Context.for_refactor_preview(operation, params, affected_files)

      # Build context for dead code analysis
      context = Context.for_dead_code_analysis(function_ref, callers, callees)
  """

  alias Ragex.Graph.{Algorithms, Store}
  alias Ragex.Retrieval.Hybrid

  require Logger

  @type context_map :: %{
          required(:type) => atom(),
          required(:primary) => any(),
          optional(:graph_context) => map(),
          optional(:semantic_context) => list(),
          optional(:metadata) => map()
        }

  @doc """
  Build context for validation error explanation.

  Includes:
  - The error message and location
  - Surrounding code context
  - Similar code patterns from the codebase
  - Common fixes for this error type

  ## Parameters
  - `error` - Validation error map with message, line, column
  - `file_path` - Path to file with error
  - `surrounding_code` - Code around the error (optional)
  - `opts` - Additional options

  ## Returns
  - Context map suitable for AI prompt
  """
  @spec for_validation_error(map(), String.t(), String.t() | nil, keyword()) :: context_map()
  def for_validation_error(error, file_path, surrounding_code \\ nil, opts \\ []) do
    error_type = extract_error_type(error)
    language = detect_language(file_path)

    # Try to find similar error patterns
    semantic_context =
      if surrounding_code do
        find_similar_patterns(surrounding_code, language, limit: 3)
      else
        []
      end

    %{
      type: :validation_error,
      primary: %{
        error: error,
        file_path: file_path,
        surrounding_code: surrounding_code,
        language: language,
        error_type: error_type
      },
      semantic_context: semantic_context,
      metadata: %{
        timestamp: DateTime.utc_now(),
        options: opts
      }
    }
  end

  @doc """
  Build context for refactoring preview commentary.

  Includes:
  - Operation type and parameters
  - Affected files and their relationships
  - Call graph context (who calls these functions)
  - Similar refactorings in the codebase
  - Complexity metrics

  ## Parameters
  - `operation` - Refactoring operation atom
  - `params` - Operation parameters
  - `affected_files` - List of file paths that will be modified
  - `opts` - Additional options

  ## Returns
  - Context map suitable for AI prompt
  """
  @spec for_refactor_preview(atom(), map(), [String.t()], keyword()) :: context_map()
  def for_refactor_preview(operation, params, affected_files, opts \\ []) do
    # Build graph context based on operation
    graph_context =
      case operation do
        :rename_function ->
          build_function_context(params[:module], params[:old_name], params[:arity])

        :rename_module ->
          build_module_context(params[:old_module])

        :extract_function ->
          build_function_context(params[:module], params[:source_function], params[:source_arity])

        _ ->
          %{}
      end

    %{
      type: :refactor_preview,
      primary: %{
        operation: operation,
        params: params,
        affected_files: affected_files,
        file_count: length(affected_files)
      },
      graph_context: graph_context,
      metadata: %{
        timestamp: DateTime.utc_now(),
        options: opts
      }
    }
  end

  @doc """
  Build context for dead code confidence refinement.

  Includes:
  - Function reference and basic info
  - Call graph (who calls it, if anyone)
  - Module behavior declarations
  - Function documentation and naming patterns
  - Similar functions in codebase

  ## Parameters
  - `function_ref` - {:function, module, name, arity} tuple
  - `opts` - Additional options

  ## Returns
  - Context map suitable for AI prompt
  """
  @spec for_dead_code_analysis(tuple(), keyword()) :: context_map()
  def for_dead_code_analysis({:function, module, name, arity} = function_ref, opts \\ []) do
    # Get function node from graph
    function_node = Store.find_node(:function, {module, name, arity})

    # Get callers
    callers = get_callers(function_ref)

    # Get module context
    module_node = Store.find_node(:module, module)

    # Check for behavior declarations
    behaviors = extract_behaviors(module_node)

    # Get similar function names (semantic similarity)
    similar_functions = find_similar_function_names(name, limit: 5)

    %{
      type: :dead_code_analysis,
      primary: %{
        function_ref: function_ref,
        function_node: function_node,
        module: module,
        name: name,
        arity: arity,
        visibility: function_node[:visibility] || :unknown
      },
      graph_context: %{
        callers: callers,
        caller_count: length(callers),
        module_behaviors: behaviors,
        similar_functions: similar_functions
      },
      metadata: %{
        timestamp: DateTime.utc_now(),
        options: opts
      }
    }
  end

  @doc """
  Build context for duplication semantic analysis.

  Includes:
  - Both code snippets
  - AST similarity metrics
  - Embedding similarity
  - Call patterns
  - Usage context

  ## Parameters
  - `code1` - First code snippet
  - `code2` - Second code snippet
  - `similarity_score` - Pre-calculated similarity score
  - `opts` - Additional options

  ## Returns
  - Context map suitable for AI prompt
  """
  @spec for_duplication_analysis(String.t(), String.t(), float(), keyword()) :: context_map()
  def for_duplication_analysis(code1, code2, similarity_score, opts \\ []) do
    location1 = Keyword.get(opts, :location1, %{})
    location2 = Keyword.get(opts, :location2, %{})

    %{
      type: :duplication_analysis,
      primary: %{
        code1: code1,
        code2: code2,
        similarity_score: similarity_score,
        location1: location1,
        location2: location2
      },
      metadata: %{
        timestamp: DateTime.utc_now(),
        options: opts
      }
    }
  end

  @doc """
  Build context for dependency insights.

  Includes:
  - Module coupling metrics
  - Dependency graph
  - Similar modules in codebase
  - Architectural patterns

  ## Parameters
  - `module` - Module atom
  - `metrics` - Coupling metrics map
  - `opts` - Additional options

  ## Returns
  - Context map suitable for AI prompt
  """
  @spec for_dependency_insights(module(), map(), keyword()) :: context_map()
  def for_dependency_insights(module, metrics, opts \\ []) do
    # Get dependencies
    dependencies = get_module_dependencies(module)
    dependents = get_module_dependents(module)

    # Find similar modules by structure
    similar_modules = find_similar_modules(module, limit: 5)

    %{
      type: :dependency_insights,
      primary: %{
        module: module,
        metrics: metrics,
        dependency_count: length(dependencies),
        dependent_count: length(dependents)
      },
      graph_context: %{
        dependencies: dependencies,
        dependents: dependents,
        similar_modules: similar_modules
      },
      metadata: %{
        timestamp: DateTime.utc_now(),
        options: opts
      }
    }
  end

  @doc """
  Build context for complexity explanation.

  Includes:
  - Function AST or code
  - Complexity metrics breakdown
  - Similar functions with lower complexity
  - Common patterns

  ## Parameters
  - `function_ref` - {:function, module, name, arity} tuple
  - `complexity_metrics` - Map of complexity metrics
  - `opts` - Additional options

  ## Returns
  - Context map suitable for AI prompt
  """
  @spec for_complexity_explanation(tuple(), map(), keyword()) :: context_map()
  def for_complexity_explanation(
        {:function, module, name, arity} = function_ref,
        complexity_metrics,
        opts \\ []
      ) do
    # Get function node
    function_node = Store.find_node(:function, {module, name, arity})

    # Find similar functions with lower complexity
    similar_simpler = find_simpler_alternatives(function_ref, complexity_metrics, limit: 3)

    %{
      type: :complexity_explanation,
      primary: %{
        function_ref: function_ref,
        function_node: function_node,
        metrics: complexity_metrics
      },
      graph_context: %{
        similar_simpler_functions: similar_simpler
      },
      metadata: %{
        timestamp: DateTime.utc_now(),
        options: opts
      }
    }
  end

  @doc """
  Convert context map to string format for AI prompt.

  Formats the context in a human-readable way suitable for inclusion
  in AI prompts.

  ## Parameters
  - `context` - Context map from any of the builder functions

  ## Returns
  - Formatted string
  """
  @spec to_prompt_string(context_map()) :: String.t()
  def to_prompt_string(context) do
    case context.type do
      :validation_error -> format_validation_context(context)
      :refactor_preview -> format_refactor_context(context)
      :dead_code_analysis -> format_dead_code_context(context)
      :duplication_analysis -> format_duplication_context(context)
      :dependency_insights -> format_dependency_context(context)
      :complexity_explanation -> format_complexity_context(context)
      _ -> inspect(context)
    end
  end

  # Private functions

  defp extract_error_type(%{message: message}) do
    cond do
      String.contains?(message, ["unexpected", "syntax"]) -> :syntax_error
      String.contains?(message, ["undefined", "not found"]) -> :undefined_reference
      String.contains?(message, ["type", "spec"]) -> :type_error
      true -> :unknown
    end
  end

  defp detect_language(file_path) do
    case Path.extname(file_path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".js" -> :javascript
      ".ts" -> :typescript
      _ -> :unknown
    end
  end

  defp find_similar_patterns(code, _language, opts) do
    limit = Keyword.get(opts, :limit, 5)

    case Hybrid.search(code, limit: limit, threshold: 0.3) do
      {:ok, results} -> Enum.take(results, limit)
      _ -> []
    end
  end

  defp build_function_context(module, function, arity) do
    function_ref = {module, function, arity}
    function_node = Store.find_node(:function, function_ref)

    callers = get_callers({:function, module, function, arity})
    callees = get_callees({:function, module, function, arity})

    # Get PageRank importance if available
    importance = get_importance(function_ref)

    %{
      function: function_node,
      callers: callers,
      caller_count: length(callers),
      callees: callees,
      callee_count: length(callees),
      importance: importance
    }
  end

  defp build_module_context(module) do
    module_node = Store.find_node(:module, module)
    
    # Get functions for this module using list_functions with module filter
    # Use large limit instead of :infinity which list_functions doesn't accept
    module_functions = Store.list_functions(module: module, limit: 10_000)

    %{
      module: module_node,
      function_count: length(module_functions),
      functions: Enum.map(module_functions, fn f -> elem(f.id, 1) end)
    }
  end

  defp get_callers({:function, module, name, arity}) do
    function_node = {:function, {module, name, arity}}

    Store.get_incoming_edges(function_node, :calls)
    |> Enum.map(fn edge -> edge.from end)
    |> Enum.uniq()
  end

  defp get_callees({:function, module, name, arity}) do
    function_node = {:function, {module, name, arity}}

    Store.get_outgoing_edges(function_node, :calls)
    |> Enum.map(fn edge -> edge.to end)
    |> Enum.uniq()
  end

  defp extract_behaviors(nil), do: []

  defp extract_behaviors(module_node) do
    module_node[:metadata][:behaviors] || []
  end

  defp find_similar_function_names(name, opts) do
    limit = Keyword.get(opts, :limit, 5)
    name_str = Atom.to_string(name)

    # Use Hybrid search for function names to find similar patterns
    case Hybrid.search(name_str, limit: limit * 2, threshold: 0.4) do
      {:ok, results} ->
        results
        |> Enum.filter(fn result -> result.node_type == :function end)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp get_module_dependencies(module) do
    module_node = {:module, module}

    Store.get_outgoing_edges(module_node, :imports)
    |> Enum.map(fn edge -> edge.to end)
    |> Enum.uniq()
  end

  defp get_module_dependents(module) do
    module_node = {:module, module}

    Store.get_incoming_edges(module_node, :imports)
    |> Enum.map(fn edge -> edge.from end)
    |> Enum.uniq()
  end

  defp find_similar_modules(module, opts) do
    limit = Keyword.get(opts, :limit, 5)
    module_str = Atom.to_string(module)

    # Use Hybrid search for modules to find similar patterns
    case Hybrid.search(module_str, limit: limit * 2, threshold: 0.4) do
      {:ok, results} ->
        results
        |> Enum.filter(fn result -> result.node_type == :module end)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp find_simpler_alternatives({:function, module, name, arity}, metrics, opts) do
    limit = Keyword.get(opts, :limit, 3)
    current_complexity = Map.get(metrics, :cyclomatic_complexity, Map.get(metrics, :complexity, 999))

    # Get all functions from the same module or similar modules
    all_functions = Store.list_functions(module: module, limit: 100)

    # Filter functions with lower complexity (if complexity data available)
    # Otherwise, find functions with similar names but different implementations
    all_functions
    |> Enum.filter(fn f ->
      {mod, func, ar} = f.id
      # Exclude self
      not (mod == module and func == name and ar == arity)
    end)
    |> Enum.map(fn f ->
      {mod, func, ar} = f.id
      # Get function node to check if it has complexity metadata
      node_data = Store.find_node(:function, {mod, func, ar})
      complexity = get_in(node_data, [:metadata, :complexity]) || 0
      %{function: f, complexity: complexity}
    end)
    |> Enum.filter(fn item ->
      # Only include if complexity is lower and not zero (unknown)
      item.complexity > 0 and item.complexity < current_complexity
    end)
    |> Enum.sort_by(fn item -> item.complexity end)
    |> Enum.take(limit)
    |> Enum.map(fn item -> item.function end)
  end

  defp get_importance(function_ref) do
    # Try to get PageRank score
    case Algorithms.pagerank() do
      {:ok, scores} ->
        Map.get(scores, function_ref, 0.0)

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  # Formatting functions

  defp format_validation_context(context) do
    primary = context.primary

    """
    ## Validation Error Context

    **File**: #{primary.file_path}
    **Language**: #{primary.language}
    **Error Type**: #{primary.error_type}
    **Error**: #{primary.error[:message]}
    **Location**: Line #{primary.error[:line]}, Column #{primary.error[:column]}

    #{if primary.surrounding_code do
      """
      **Surrounding Code**:
      ```
      #{primary.surrounding_code}
      ```
      """
    end}

    #{if match?([_ | _], context.semantic_context) do
      """
      **Similar Patterns Found**:
      #{Enum.map_join(context.semantic_context, "\n", fn result -> format_search_result(result) end)}
      """
    end}
    """
  end

  defp format_refactor_context(context) do
    primary = context.primary

    """
    ## Refactoring Preview Context

    **Operation**: #{primary.operation}
    **Files Affected**: #{primary.file_count}
    **Files**: #{Enum.join(primary.affected_files, ", ")}

    #{if context.graph_context do
      graph = context.graph_context

      """
      **Function Context**:
      - Callers: #{graph[:caller_count] || 0}
      - Callees: #{graph[:callee_count] || 0}
      - Importance: #{Float.round(graph[:importance] || 0.0, 3)}
      """
    end}
    """
  end

  defp format_dead_code_context(context) do
    primary = context.primary
    graph = context.graph_context

    """
    ## Dead Code Analysis Context

    **Function**: #{primary.module}.#{primary.name}/#{primary.arity}
    **Visibility**: #{primary.visibility}
    **Callers**: #{graph.caller_count}
    **Module Behaviors**: #{inspect(graph.module_behaviors)}

    #{if match?([_ | _], graph.similar_functions) do
      """
      **Similar Functions**:
      #{Enum.map_join(graph.similar_functions, "\n", fn result -> format_search_result(result) end)}
      """
    end}
    """
  end

  defp format_duplication_context(context) do
    primary = context.primary

    """
    ## Code Duplication Context

    **Similarity Score**: #{Float.round(primary.similarity_score, 2)}

    **Code Snippet 1**:
    ```
    #{primary.code1}
    ```

    **Code Snippet 2**:
    ```
    #{primary.code2}
    ```
    """
  end

  defp format_dependency_context(context) do
    primary = context.primary
    graph = context.graph_context

    """
    ## Dependency Analysis Context

    **Module**: #{primary.module}
    **Dependencies**: #{primary.dependency_count}
    **Dependents**: #{primary.dependent_count}

    **Coupling Metrics**:
    #{Enum.map_join(primary.metrics, "\n", fn {k, v} -> "- #{k}: #{v}" end)}

    #{if match?([_ | _], graph.similar_modules) do
      """
      **Similar Modules**:
      #{Enum.map_join(graph.similar_modules, "\n", fn result -> format_search_result(result) end)}
      """
    end}
    """
  end

  defp format_complexity_context(context) do
    primary = context.primary

    """
    ## Complexity Analysis Context

    **Function**: #{elem(primary.function_ref, 1)}.#{elem(primary.function_ref, 2)}/#{elem(primary.function_ref, 3)}

    **Complexity Metrics**:
    #{Enum.map_join(primary.metrics, "\n", fn {k, v} -> "- #{k}: #{v}" end)}

    #{if match?([_ | _], context.graph_context[:similar_simpler_functions]) do
      """
      **Simpler Alternatives**:
      #{Enum.map_join(context.graph_context[:similar_simpler_functions], "\n", fn func -> format_function_ref(func) end)}
      """
    end}
    """
  end

  # Helper to format search results from Hybrid.search
  defp format_search_result(result) do
    # Extract meaningful name from result
    name =
      case result do
        %{node_type: :function, node_id: {module, func, arity}} ->
          "#{module}.#{func}/#{arity}"

        %{node_type: :module, node_id: module} ->
          "#{module}"

        %{text: text} when is_binary(text) ->
          # Truncate long text
          if String.length(text) > 60 do
            String.slice(text, 0, 57) <> "..."
          else
            text
          end

        _ ->
          "unknown"
      end

    score = Float.round(result.score, 2)
    "- #{name} (similarity: #{score})"
  end

  # Helper to format function reference from list_functions
  defp format_function_ref(%{id: {module, name, arity}}) do
    "- #{module}.#{name}/#{arity}"
  end

  defp format_function_ref(other) do
    "- #{inspect(other)}"
  end
end
