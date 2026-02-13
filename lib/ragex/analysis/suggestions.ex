defmodule Ragex.Analysis.Suggestions do
  @moduledoc """
  Automated refactoring suggestion engine.

  Analyzes code to identify refactoring opportunities by combining:
  - Code duplication detection (Type I-IV clones)
  - Dead code detection (interprocedural + intraprocedural)
  - Quality metrics (complexity, coupling, instability)
  - Impact analysis (risk scoring, effort estimation)
  - Dependency analysis (circular dependencies, god modules)

  Each suggestion includes:
  - Pattern type (extract_function, split_module, etc.)
  - Priority level (critical, high, medium, low, info)
  - Actionable plan with step-by-step instructions
  - RAG-powered context-aware advice (optional)

  ## Usage

      alias Ragex.Analysis.Suggestions

      # Analyze a module for refactoring opportunities
      {:ok, suggestions} = Suggestions.analyze_target({:module, MyModule})

      # Analyze a file
      {:ok, suggestions} = Suggestions.analyze_target("lib/my_module.ex")

      # Analyze a directory
      {:ok, suggestions} = Suggestions.analyze_target("lib/", recursive: true)

      # Filter by priority
      {:ok, high_priority} = Suggestions.analyze_target(target, min_priority: :high)

      # Get specific patterns only
      {:ok, complexity} = Suggestions.analyze_target(target, patterns: [:simplify_complexity])
  """

  alias Ragex.Analysis.{DeadCode, DependencyGraph, Duplication, Quality}
  alias Ragex.Analysis.Suggestions.{Actions, Patterns, RAGAdvisor, Ranker}
  alias Ragex.Graph.Store

  require Logger

  @type target ::
          {:module, module()}
          | {:function, module(), atom(), non_neg_integer()}
          | String.t()

  @type pattern ::
          :extract_function
          | :inline_function
          | :split_module
          | :merge_modules
          | :remove_dead_code
          | :reduce_coupling
          | :simplify_complexity
          | :extract_module

  @type priority :: :critical | :high | :medium | :low | :info

  @type suggestion :: %{
          id: String.t(),
          pattern: pattern(),
          priority: priority(),
          priority_score: float(),
          target: map(),
          reason: String.t(),
          metrics: map(),
          impact: map(),
          effort: map(),
          benefit: String.t(),
          confidence: float(),
          rag_advice: String.t() | nil,
          action_plan: map() | nil,
          examples: [String.t()]
        }

  @type analysis_result :: %{
          suggestions: [suggestion()],
          summary: map(),
          target: target(),
          analyzed_at: DateTime.t()
        }

  @doc """
  Analyzes a target (module, function, file, or directory) for refactoring opportunities.

  ## Parameters
  - `target` - Target to analyze:
    - `{:module, module()}` - Analyze a specific module
    - `{:function, module, name, arity}` - Analyze a specific function
    - `string` - File or directory path
  - `opts` - Keyword list of options:
    - `:patterns` - Filter by pattern types (default: all)
    - `:min_priority` - Minimum priority level (default: :low)
    - `:include_actions` - Include action plans (default: true)
    - `:use_rag` - Use RAG for enhanced advice (default: false)
    - `:recursive` - For directories, scan recursively (default: true)

  ## Returns
  - `{:ok, analysis_result}` - Analysis with suggestions
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      iex> {:ok, analysis} = Suggestions.analyze_target({:module, MyModule})
      iex> length(analysis.suggestions)
      5
  """
  @spec analyze_target(target(), keyword()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze_target(target, opts \\ []) do
    Logger.info("Analyzing target for refactoring suggestions: #{inspect(target)}")

    with {:ok, analysis_data} <- gather_analysis_data(target, opts),
         {:ok, raw_suggestions} <- detect_patterns(analysis_data, opts),
         {:ok, scored_suggestions} <- score_and_prioritize(raw_suggestions, opts),
         {:ok, enriched_suggestions} <- enrich_suggestions(scored_suggestions, opts) do
      result = %{
        suggestions: enriched_suggestions,
        summary: build_summary(enriched_suggestions),
        target: target,
        analyzed_at: DateTime.utc_now()
      }

      {:ok, result}
    end
  end

  @doc """
  Generates suggestions for a specific pattern type.

  ## Parameters
  - `target` - Target to analyze
  - `pattern` - Pattern type to detect
  - `opts` - Options (same as analyze_target/2)

  ## Returns
  - `{:ok, [suggestion]}` - List of suggestions for the pattern
  - `{:error, reason}` - Error if analysis fails
  """
  @spec suggest_for_pattern(target(), pattern(), keyword()) ::
          {:ok, [suggestion()]} | {:error, term()}
  def suggest_for_pattern(target, pattern, opts \\ []) do
    opts = Keyword.put(opts, :patterns, [pattern])

    case analyze_target(target, opts) do
      {:ok, result} -> {:ok, result.suggestions}
      error -> error
    end
  end

  # Private functions

  defp gather_analysis_data(target, opts) do
    Logger.debug("Gathering analysis data for #{inspect(target)}")

    try do
      # Validate target format
      unless valid_target?(target) do
        raise ArgumentError,
              "Invalid target format: #{inspect(target)}. Expected file path, directory path, {:module, module}, or {:function, module, name, arity}"
      end

      data = %{
        target: target,
        quality: gather_quality_metrics(target),
        duplication: gather_duplication_data(target, opts),
        dead_code: gather_dead_code_data(target),
        dependencies: gather_dependency_data(target),
        graph_info: gather_graph_info(target)
      }

      {:ok, data}
    rescue
      e ->
        Logger.error(
          "Failed to gather analysis data: #{Exception.format(:error, e, __STACKTRACE__)}"
        )

        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  # Validate target format
  defp valid_target?({:module, module}) when is_atom(module), do: true

  defp valid_target?({:function, module, name, arity})
       when is_atom(module) and is_atom(name) and is_integer(arity), do: true

  defp valid_target?(path) when is_binary(path), do: true
  defp valid_target?(_), do: false

  defp gather_quality_metrics(target) do
    case target do
      {:module, module} ->
        case Quality.analyze_module(module) do
          {:ok, metrics} -> metrics
          _ -> %{}
        end

      {:function, module, name, arity} ->
        case Quality.analyze_function(module, name, arity) do
          {:ok, metrics} -> metrics
          _ -> %{}
        end

      path when is_binary(path) ->
        if File.dir?(path) do
          case Quality.analyze_directory(path) do
            {:ok, metrics} -> metrics
            _ -> %{}
          end
        else
          case Quality.analyze_file(path) do
            {:ok, metrics} -> metrics
            _ -> %{}
          end
        end

      _ ->
        %{}
    end
  end

  defp gather_duplication_data(target, opts) do
    case target do
      path when is_binary(path) ->
        if File.dir?(path) do
          case Duplication.detect_in_directory(path, opts) do
            {:ok, clones} -> %{clones: clones, count: length(clones)}
            _ -> %{clones: [], count: 0}
          end
        else
          %{clones: [], count: 0}
        end

      _ ->
        %{clones: [], count: 0}
    end
  end

  defp gather_dead_code_data(target) do
    case target do
      {:module, module} ->
        case DeadCode.find_in_module(module) do
          {:ok, dead} -> %{dead_functions: dead, count: length(dead)}
          _ -> %{dead_functions: [], count: 0}
        end

      path when is_binary(path) ->
        if File.dir?(path) do
          %{dead_functions: [], count: 0}
        else
          case DeadCode.analyze_file(path) do
            {:ok, dead} -> %{dead_functions: dead, count: length(dead)}
            _ -> %{dead_functions: [], count: 0}
          end
        end

      _ ->
        %{dead_functions: [], count: 0}
    end
  end

  defp gather_dependency_data(target) do
    case target do
      {:module, module} ->
        case DependencyGraph.analyze_module(module) do
          {:ok, deps} -> deps
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp gather_graph_info(target) do
    case target do
      {:module, module} ->
        functions = Store.list_functions(module)
        %{function_count: length(functions), functions: functions}

      {:function, module, name, arity} ->
        case Store.get_function(module, name, arity) do
          {:ok, node} -> %{node: node}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp detect_patterns(analysis_data, opts) do
    Logger.debug("Detecting refactoring patterns")

    pattern_filter = Keyword.get(opts, :patterns, :all)

    suggestions =
      Patterns.all_patterns()
      |> Enum.filter(fn pattern ->
        pattern_filter == :all || pattern in pattern_filter
      end)
      |> Enum.flat_map(fn pattern ->
        case Patterns.detect(pattern, analysis_data, opts) do
          {:ok, pattern_suggestions} -> pattern_suggestions
          {:error, _reason} -> []
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, suggestions}
  rescue
    e ->
      Logger.error("Failed to detect patterns: #{inspect(e)}")
      {:error, {:pattern_detection_failed, Exception.message(e)}}
  end

  defp score_and_prioritize(suggestions, _opts) do
    Logger.debug("Scoring and prioritizing #{length(suggestions)} suggestions")

    scored =
      suggestions
      |> Enum.map(&Ranker.score_suggestion/1)
      |> Enum.sort_by(& &1.priority_score, :desc)

    {:ok, scored}
  rescue
    e ->
      Logger.error("Failed to score suggestions: #{inspect(e)}")
      {:error, {:scoring_failed, Exception.message(e)}}
  end

  defp enrich_suggestions(suggestions, opts) do
    include_actions = Keyword.get(opts, :include_actions, true)
    use_rag = Keyword.get(opts, :use_rag, false)
    min_priority = Keyword.get(opts, :min_priority, :low)

    enriched =
      suggestions
      |> Enum.filter(&meets_priority_threshold?(&1, min_priority))
      |> Enum.map(fn suggestion ->
        suggestion
        |> maybe_add_action_plan(include_actions)
        |> maybe_add_rag_advice(use_rag)
      end)

    {:ok, enriched}
  rescue
    e ->
      Logger.error("Failed to enrich suggestions: #{inspect(e)}")
      {:error, {:enrichment_failed, Exception.message(e)}}
  end

  defp meets_priority_threshold?(suggestion, min_priority) do
    priority_order = [:info, :low, :medium, :high, :critical]

    min_index = Enum.find_index(priority_order, &(&1 == min_priority))
    suggestion_index = Enum.find_index(priority_order, &(&1 == suggestion.priority))

    suggestion_index >= min_index
  end

  defp maybe_add_action_plan(suggestion, false), do: suggestion

  defp maybe_add_action_plan(suggestion, true) do
    case Actions.generate_action_plan(suggestion) do
      {:ok, plan} -> Map.put(suggestion, :action_plan, plan)
      {:error, _} -> Map.put(suggestion, :action_plan, nil)
    end
  end

  defp maybe_add_rag_advice(suggestion, false) do
    Map.put(suggestion, :rag_advice, nil)
  end

  defp maybe_add_rag_advice(suggestion, true) do
    case RAGAdvisor.generate_advice(suggestion) do
      {:ok, advice} -> Map.put(suggestion, :rag_advice, advice)
      {:error, _} -> Map.put(suggestion, :rag_advice, nil)
    end
  end

  defp build_summary(suggestions) do
    %{
      total: length(suggestions),
      by_priority: count_by_priority(suggestions),
      by_pattern: count_by_pattern(suggestions),
      average_score: calculate_average_score(suggestions)
    }
  end

  defp count_by_priority(suggestions) do
    suggestions
    |> Enum.group_by(& &1.priority)
    |> Enum.map(fn {priority, list} -> {priority, length(list)} end)
    |> Enum.into(%{})
  end

  defp count_by_pattern(suggestions) do
    suggestions
    |> Enum.group_by(& &1.pattern)
    |> Enum.map(fn {pattern, list} -> {pattern, length(list)} end)
    |> Enum.into(%{})
  end

  defp calculate_average_score([]), do: 0.0

  defp calculate_average_score([_ | _] = suggestions) do
    total = Enum.reduce(suggestions, 0.0, fn s, acc -> acc + s.priority_score end)
    Float.round(total / length(suggestions), 2)
  end
end
