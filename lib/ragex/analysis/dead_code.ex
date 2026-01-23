defmodule Ragex.Analysis.DeadCode do
  @moduledoc """
  Dead code detection for identifying unused functions and code.

  Analyzes the knowledge graph to find:
  - Unused public functions (exported but never called externally)
  - Unused private functions (never called within module)
  - Functions with low confidence of being dead (potential entry points, callbacks)

  Provides confidence scores to help distinguish between truly dead code and
  potential entry points (callbacks, GenServer handlers, etc.).
  """

  alias Ragex.Graph.Store
  require Logger

  @type function_ref :: {:function, module(), atom(), non_neg_integer()}
  @type confidence :: float()
  @type dead_function :: %{
          function: function_ref(),
          confidence: confidence(),
          reason: String.t(),
          visibility: :public | :private,
          module: module(),
          metadata: map()
        }
  @type suggestion :: %{
          type: :remove_function | :review_function | :potential_callback,
          confidence: confidence(),
          target: function_ref(),
          description: String.t(),
          metadata: map()
        }

  # Known callback patterns that should not be flagged as dead code
  @callback_patterns [
    # GenServer callbacks
    {:init, 1},
    {:handle_call, 3},
    {:handle_cast, 2},
    {:handle_info, 2},
    {:terminate, 2},
    {:code_change, 3},
    # GenStage callbacks
    {:handle_demand, 2},
    {:handle_events, 3},
    {:handle_subscribe, 4},
    {:handle_cancel, 3},
    # Supervisor callbacks
    {:start_link, 1},
    # Phoenix callbacks
    {:mount, 3},
    {:handle_event, 3},
    {:handle_params, 3},
    {:render, 1},
    # Test callbacks
    {:setup, 1},
    {:setup_all, 1},
    # Mix tasks
    {:run, 1},
    # Application callbacks
    {:start, 2},
    {:stop, 1}
  ]

  # Entry point detection patterns
  @entry_point_patterns [
    ~r/^main$/,
    ~r/^run$/,
    ~r/^start/,
    ~r/^handle_/,
    ~r/^mount$/,
    ~r/^render$/,
    ~r/^test_/
  ]

  @doc """
  Finds unused public (exported) functions.

  Public functions with no callers are potentially dead code, but may be:
  - Entry points (main, CLI commands)
  - Callbacks (GenServer, Supervisor, Phoenix)
  - API functions not yet used
  - Test helpers

  Returns functions with confidence scores indicating likelihood of being dead.

  ## Parameters
  - `opts`: Keyword list of options
    - `:min_confidence` - Minimum confidence threshold (0.0-1.0, default: 0.5)
    - `:exclude_tests` - Exclude test modules (default: true)
    - `:include_callbacks` - Include potential callbacks (default: false)

  ## Returns
  - `{:ok, [dead_function]}` - List of potentially unused functions with confidence scores
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      # Find unused exports with high confidence
      {:ok, dead} = find_unused_exports(min_confidence: 0.8)

      # Include potential callbacks
      {:ok, all} = find_unused_exports(include_callbacks: true, min_confidence: 0.3)
  """
  @spec find_unused_exports(keyword()) :: {:ok, [dead_function()]} | {:error, term()}
  def find_unused_exports(opts \\ []) do
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)
    exclude_tests = Keyword.get(opts, :exclude_tests, true)
    include_callbacks = Keyword.get(opts, :include_callbacks, false)

    try do
      functions = Store.list_nodes(:function, :infinity)

      dead_functions =
        functions
        |> Enum.filter(fn func ->
          is_public_function?(func) && should_check_module?(func, exclude_tests)
        end)
        |> Enum.map(&analyze_function/1)
        |> Enum.filter(fn result ->
          result != nil &&
            (include_callbacks || result.confidence >= min_confidence) &&
            result.confidence >= min_confidence
        end)
        |> Enum.sort_by(& &1.confidence, :desc)

      {:ok, dead_functions}
    rescue
      e ->
        Logger.error("Failed to find unused exports: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  @doc """
  Finds unused private functions.

  Private functions with no callers within their module are likely dead code.
  Higher confidence than public functions since private functions are not part of the API.

  ## Parameters
  - `opts`: Keyword list of options
    - `:min_confidence` - Minimum confidence threshold (default: 0.7)
    - `:exclude_tests` - Exclude test modules (default: true)

  ## Returns
  - `{:ok, [dead_function]}` - List of unused private functions
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, dead} = find_unused_private()
  """
  @spec find_unused_private(keyword()) :: {:ok, [dead_function()]} | {:error, term()}
  def find_unused_private(opts \\ []) do
    min_confidence = Keyword.get(opts, :min_confidence, 0.7)
    exclude_tests = Keyword.get(opts, :exclude_tests, true)

    try do
      functions = Store.list_nodes(:function, :infinity)

      dead_functions =
        functions
        |> Enum.filter(fn func ->
          is_private_function?(func) && should_check_module?(func, exclude_tests)
        end)
        |> Enum.map(&analyze_function/1)
        |> Enum.filter(fn result ->
          result != nil && result.confidence >= min_confidence
        end)
        |> Enum.sort_by(& &1.confidence, :desc)

      {:ok, dead_functions}
    rescue
      e ->
        Logger.error("Failed to find unused private functions: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  @doc """
  Finds all unused functions (both public and private).

  Combines results from `find_unused_exports/1` and `find_unused_private/1`.

  ## Parameters
  - `opts`: Keyword list of options (same as individual functions)

  ## Returns
  - `{:ok, [dead_function]}` - Combined list of unused functions

  ## Examples

      {:ok, all_dead} = find_all_unused(min_confidence: 0.6)
  """
  @spec find_all_unused(keyword()) :: {:ok, [dead_function()]} | {:error, term()}
  def find_all_unused(opts \\ []) do
    with {:ok, exports} <- find_unused_exports(opts),
         {:ok, private} <- find_unused_private(opts) do
      all = (exports ++ private) |> Enum.sort_by(& &1.confidence, :desc)
      {:ok, all}
    end
  end

  @doc """
  Finds unused modules (modules with no external references).

  Delegates to `DependencyGraph.find_unused/1` for consistency.

  ## Parameters
  - `opts`: Keyword list of options (passed to DependencyGraph)

  ## Returns
  - `{:ok, [module_name]}` - List of unused modules
  - `{:error, reason}` - Error if analysis fails
  """
  @spec find_unused_modules(keyword()) :: {:ok, [module()]} | {:error, term()}
  def find_unused_modules(opts \\ []) do
    # Delegate to DependencyGraph for consistency
    alias Ragex.Analysis.DependencyGraph
    DependencyGraph.find_unused(opts)
  end

  @doc """
  Generates removal suggestions based on dead code analysis.

  Categorizes dead code into:
  - Safe to remove (high confidence)
  - Review recommended (medium confidence)
  - Potential callbacks (low confidence, may be entry points)

  ## Parameters
  - `opts`: Keyword list of options
    - `:min_confidence` - Minimum confidence for suggestions (default: 0.5)
    - `:group_by_module` - Group suggestions by module (default: true)

  ## Returns
  - `{:ok, [suggestion]}` - List of removal suggestions
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, suggestions} = removal_suggestions()
      # Process suggestions...
  """
  @spec removal_suggestions(keyword()) :: {:ok, [suggestion()]} | {:error, term()}
  def removal_suggestions(opts \\ []) do
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)
    group_by_module = Keyword.get(opts, :group_by_module, true)

    with {:ok, dead_functions} <- find_all_unused(opts) do
      suggestions =
        dead_functions
        |> Enum.map(&create_suggestion/1)
        |> Enum.filter(fn s -> s.confidence >= min_confidence end)

      suggestions =
        if group_by_module do
          suggestions
          |> Enum.group_by(fn s -> extract_module(s.target) end)
          |> Enum.flat_map(fn {_module, module_suggestions} ->
            if length(module_suggestions) > 1 do
              # Create a summary suggestion for the module
              create_module_summary_suggestion(module_suggestions)
            else
              module_suggestions
            end
          end)
        else
          suggestions
        end

      {:ok, suggestions}
    end
  end

  @doc """
  Calculates a confidence score for dead code detection.

  Takes into account:
  - Function name patterns (callbacks, entry points)
  - Visibility (public vs private)
  - Number of callers
  - Module characteristics (test, Mix task, etc.)

  ## Returns
  - Float between 0.0 (definitely not dead) and 1.0 (definitely dead)
  """
  @spec confidence_score(function_ref(), map()) :: confidence()
  def confidence_score(func_ref, metadata) do
    {module, name, arity} = extract_func_parts(func_ref)

    # Base confidence based on callers
    caller_count = count_callers(func_ref)
    base_confidence = if caller_count == 0, do: 1.0, else: 0.0

    # Adjust for visibility
    visibility = Map.get(metadata, :visibility, :public)
    visibility_modifier = if visibility == :private, do: 0.0, else: -0.2

    # Adjust for callback patterns
    callback_modifier =
      if is_callback_pattern?(name, arity) do
        -0.7
      else
        0.0
      end

    # Adjust for entry point patterns
    entry_point_modifier =
      if is_entry_point_pattern?(name) do
        -0.5
      else
        0.0
      end

    # Adjust for module type
    module_modifier =
      cond do
        is_test_module?(module) -> -0.3
        is_mix_task?(module) -> -0.4
        true -> 0.0
      end

    # Calculate final confidence
    confidence =
      base_confidence + visibility_modifier + callback_modifier + entry_point_modifier +
        module_modifier

    # Clamp to [0.0, 1.0]
    max(0.0, min(1.0, confidence))
  end

  # Private functions

  # Analyze a function to determine if it's dead code
  defp analyze_function(%{id: {module, name, arity}, data: metadata}) do
    func_ref = {:function, module, name, arity}
    caller_count = count_callers(func_ref)

    if caller_count == 0 do
      confidence = confidence_score(func_ref, metadata)
      visibility = Map.get(metadata, :visibility, :public)

      reason =
        cond do
          confidence > 0.8 -> "No callers found, likely dead code"
          confidence > 0.5 -> "No callers found, but may be entry point or callback"
          true -> "Potential callback or entry point with no callers"
        end

      %{
        function: func_ref,
        confidence: confidence,
        reason: reason,
        visibility: visibility,
        module: module,
        metadata: metadata
      }
    else
      nil
    end
  end

  # Count the number of callers for a function
  defp count_callers(func_ref) do
    Store.get_incoming_edges(func_ref, :calls)
    |> length()
  end

  # Check if function is public
  defp is_public_function?(%{data: metadata}) do
    Map.get(metadata, :visibility, :public) == :public
  end

  # Check if function is private
  defp is_private_function?(%{data: metadata}) do
    Map.get(metadata, :visibility, :public) == :private
  end

  # Check if we should analyze this module
  defp should_check_module?(%{id: {module, _name, _arity}}, exclude_tests) do
    if exclude_tests do
      !is_test_module?(module)
    else
      true
    end
  end

  # Check if function matches callback patterns
  defp is_callback_pattern?(name, arity) do
    {name, arity} in @callback_patterns
  end

  # Check if function name matches entry point patterns
  defp is_entry_point_pattern?(name) do
    name_str = Atom.to_string(name)

    Enum.any?(@entry_point_patterns, fn pattern ->
      Regex.match?(pattern, name_str)
    end)
  end

  # Check if module is a test module
  defp is_test_module?(module) do
    module_str = to_string(module)
    String.ends_with?(module_str, "Test") || String.contains?(module_str, ".Test.")
  end

  # Check if module is a Mix task
  defp is_mix_task?(module) do
    module_str = to_string(module)
    String.starts_with?(module_str, "Mix.Tasks.")
  end

  # Extract module, name, arity from function reference
  defp extract_func_parts({:function, module, name, arity}), do: {module, name, arity}

  # Create a suggestion from a dead function
  defp create_suggestion(%{function: func_ref, confidence: confidence} = dead_func) do
    {module, name, arity} = extract_func_parts(func_ref)

    {type, description} =
      cond do
        confidence > 0.8 ->
          {:remove_function,
           "Function #{module}.#{name}/#{arity} appears to be dead code and can be removed"}

        confidence > 0.5 ->
          {:review_function,
           "Function #{module}.#{name}/#{arity} has no callers - review whether it's still needed"}

        true ->
          {:potential_callback,
           "Function #{module}.#{name}/#{arity} may be a callback or entry point - verify before removing"}
      end

    %{
      type: type,
      confidence: confidence,
      target: func_ref,
      description: description,
      metadata: Map.get(dead_func, :metadata, %{})
    }
  end

  # Extract module from function reference
  defp extract_module({:function, module, _name, _arity}), do: module

  # Create a module-level summary suggestion
  defp create_module_summary_suggestion(module_suggestions) do
    module = extract_module(List.first(module_suggestions).target)

    avg_confidence =
      Enum.sum(Enum.map(module_suggestions, & &1.confidence)) / length(module_suggestions)

    function_count = length(module_suggestions)

    high_confidence = Enum.count(module_suggestions, fn s -> s.confidence > 0.8 end)

    medium_confidence =
      Enum.count(module_suggestions, fn s -> s.confidence > 0.5 && s.confidence <= 0.8 end)

    low_confidence = Enum.count(module_suggestions, fn s -> s.confidence <= 0.5 end)

    description =
      """
      Module #{module} has #{function_count} potentially unused functions:
      - #{high_confidence} with high confidence (can be removed)
      - #{medium_confidence} requiring review
      - #{low_confidence} potential callbacks/entry points
      """
      |> String.trim()

    [
      %{
        type: :review_function,
        confidence: avg_confidence,
        target: {:module, module},
        description: description,
        metadata: %{
          function_count: function_count,
          functions: Enum.map(module_suggestions, & &1.target),
          breakdown: %{
            high_confidence: high_confidence,
            medium_confidence: medium_confidence,
            low_confidence: low_confidence
          }
        }
      }
    ]
  end
end
