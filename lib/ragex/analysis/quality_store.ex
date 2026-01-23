defmodule Ragex.Analysis.QualityStore do
  @moduledoc """
  Stores and queries code quality metrics in the knowledge graph.

  Extends the graph with quality metrics nodes that store analysis results
  from MetastaticBridge. Provides querying capabilities for finding code
  that exceeds quality thresholds and generating project-wide statistics.

  ## Usage

      alias Ragex.Analysis.{MetastaticBridge, QualityStore}

      # Analyze and store metrics
      {:ok, result} = MetastaticBridge.analyze_file("lib/my_module.ex")
      :ok = QualityStore.store_metrics(result)

      # Query metrics
      {:ok, metrics} = QualityStore.get_metrics("lib/my_module.ex")

      # Find complex files
      complex_files = QualityStore.find_by_threshold(:cyclomatic, 10)

      # Get project stats
      stats = QualityStore.project_stats()
  """

  alias Ragex.Graph.Store
  require Logger

  @quality_metrics_type :quality_metrics

  @doc """
  Stores quality metrics for a file in the knowledge graph.

  Creates or updates a quality_metrics node with the analysis results.

  ## Examples

      result = %{
        path: "lib/my_module.ex",
        language: :elixir,
        complexity: %{cyclomatic: 5, cognitive: 3},
        purity: %{pure?: false, effects: [:io]},
        timestamp: DateTime.utc_now()
      }

      :ok = QualityStore.store_metrics(result)
  """
  @spec store_metrics(analysis_result :: map()) :: :ok | {:error, term()}
  def store_metrics(%{path: path} = result) do
    node_id = metrics_node_id(path)

    metadata = %{
      path: path,
      language: result.language,
      cyclomatic: get_in(result, [:complexity, :cyclomatic]) || 0,
      cognitive: get_in(result, [:complexity, :cognitive]) || 0,
      max_nesting: get_in(result, [:complexity, :max_nesting]) || 0,
      halstead: get_in(result, [:complexity, :halstead]) || %{},
      loc: get_in(result, [:complexity, :loc]) || %{},
      function_metrics: get_in(result, [:complexity, :function_metrics]) || %{},
      per_function: get_in(result, [:complexity, :per_function]) || %{},
      purity_pure?: get_in(result, [:purity, :pure?]) |> boolean_default(true),
      purity_effects: get_in(result, [:purity, :effects]) || [],
      purity_confidence: get_in(result, [:purity, :confidence]) || :unknown,
      warnings: result[:warnings] || [],
      timestamp: result[:timestamp] || DateTime.utc_now(),
      # Store error info if present
      error: result[:error]
    }

    Store.add_node(@quality_metrics_type, node_id, metadata)
    :ok
  rescue
    e ->
      Logger.error("Failed to store metrics for #{path}: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Retrieves quality metrics for a specific file.

  ## Examples

      {:ok, metrics} = QualityStore.get_metrics("lib/my_module.ex")
      metrics.cyclomatic  # => 5
  """
  @spec get_metrics(path :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_metrics(path) do
    node_id = metrics_node_id(path)

    case Store.find_node(@quality_metrics_type, node_id) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  @doc """
  Finds all files where a specific metric exceeds a threshold.

  ## Options

  - `:operator` - Comparison operator: `:gt`, `:gte`, `:lt`, `:lte`, `:eq` (default: `:gt`)

  ## Examples

      # Find files with cyclomatic complexity > 10
      files = QualityStore.find_by_threshold(:cyclomatic, 10)

      # Find files with cognitive complexity >= 15
      files = QualityStore.find_by_threshold(:cognitive, 15, operator: :gte)
  """
  @spec find_by_threshold(metric :: atom(), threshold :: number(), opts :: keyword()) :: [
          String.t()
        ]
  def find_by_threshold(metric, threshold, opts \\ []) do
    operator = Keyword.get(opts, :operator, :gt)

    Store.list_nodes(@quality_metrics_type, :infinity)
    |> Enum.filter(fn node ->
      value = Map.get(node.data, metric)
      value != nil and compare(value, threshold, operator)
    end)
    |> Enum.map(fn node -> node.data.path end)
  end

  @doc """
  Finds files with any warning.

  ## Examples

      files_with_warnings = QualityStore.find_with_warnings()
  """
  @spec find_with_warnings() :: [{String.t(), [String.t()]}]
  def find_with_warnings do
    Store.list_nodes(@quality_metrics_type, :infinity)
    |> Enum.filter(fn node ->
      warnings = Map.get(node.data, :warnings, [])
      length(warnings) > 0
    end)
    |> Enum.map(fn node ->
      {node.data.path, node.data.warnings}
    end)
  end

  @doc """
  Finds impure functions (files with side effects).

  ## Examples

      impure_files = QualityStore.find_impure()
  """
  @spec find_impure() :: [String.t()]
  def find_impure do
    Store.list_nodes(@quality_metrics_type, :infinity)
    |> Enum.filter(fn node ->
      Map.get(node.data, :purity_pure?) == false
    end)
    |> Enum.map(fn node -> node.data.path end)
  end

  @doc """
  Returns project-wide quality statistics.

  Aggregates metrics across all analyzed files.

  ## Examples

      stats = QualityStore.project_stats()
      stats.total_files           # => 42
      stats.avg_cyclomatic        # => 3.5
      stats.files_with_warnings   # => 5
  """
  @spec project_stats() :: map()
  def project_stats do
    metrics_nodes = Store.list_nodes(@quality_metrics_type, :infinity)

    total_files = length(metrics_nodes)

    if total_files == 0 do
      empty_stats()
    else
      calculate_stats(metrics_nodes, total_files)
    end
  end

  @doc """
  Returns quality metrics grouped by language.

  ## Examples

      by_lang = QualityStore.stats_by_language()
      by_lang[:elixir].avg_cyclomatic  # => 4.2
  """
  @spec stats_by_language() :: %{atom() => map()}
  def stats_by_language do
    Store.list_nodes(@quality_metrics_type, :infinity)
    |> Enum.group_by(fn node -> node.data.language end)
    |> Enum.map(fn {lang, nodes} ->
      {lang, calculate_stats(nodes, length(nodes))}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Returns the top N most complex files.

  ## Options

  - `:metric` - Which metric to use: `:cyclomatic` (default), `:cognitive`, `:nesting`
  - `:limit` - Number of results (default: 10)

  ## Examples

      top_complex = QualityStore.most_complex(metric: :cyclomatic, limit: 5)
  """
  @spec most_complex(opts :: keyword()) :: [{String.t(), number()}]
  def most_complex(opts \\ []) do
    metric = Keyword.get(opts, :metric, :cyclomatic)
    limit = Keyword.get(opts, :limit, 10)

    Store.list_nodes(@quality_metrics_type, :infinity)
    |> Enum.map(fn node ->
      {node.data.path, Map.get(node.data, metric, 0)}
    end)
    |> Enum.sort_by(fn {_path, value} -> value end, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Clears all quality metrics from the graph.

  Useful for testing or re-analysis.

  ## Examples

      :ok = QualityStore.clear_all()
  """
  @spec clear_all() :: :ok
  def clear_all do
    # Since Store doesn't have a remove_node API, we must clear everything
    # This will remove all graph nodes, not just quality metrics
    # In a real implementation, we might want a separate ETS table for quality metrics
    Store.clear()
    :ok
  end

  @doc """
  Returns the number of files with quality metrics stored.

  ## Examples

      count = QualityStore.count()  # => 42
  """
  @spec count() :: non_neg_integer()
  def count do
    Store.list_nodes(@quality_metrics_type, :infinity)
    |> length()
  end

  # Private functions

  defp metrics_node_id(path) do
    # Use path hash as node ID to ensure uniqueness
    "quality_metrics:" <> Base.encode16(:crypto.hash(:sha256, path), case: :lower)
  end

  defp compare(value, threshold, :gt), do: value > threshold
  defp compare(value, threshold, :gte), do: value >= threshold
  defp compare(value, threshold, :lt), do: value < threshold
  defp compare(value, threshold, :lte), do: value <= threshold
  defp compare(value, threshold, :eq), do: value == threshold

  defp empty_stats do
    %{
      total_files: 0,
      avg_cyclomatic: 0.0,
      avg_cognitive: 0.0,
      avg_nesting: 0.0,
      max_cyclomatic: 0,
      max_cognitive: 0,
      max_nesting: 0,
      min_cyclomatic: 0,
      min_cognitive: 0,
      min_nesting: 0,
      files_with_warnings: 0,
      impure_files: 0,
      languages: %{}
    }
  end

  defp calculate_stats(nodes, total_files) do
    cyclomatic_values = Enum.map(nodes, fn n -> n.data.cyclomatic || 0 end)
    cognitive_values = Enum.map(nodes, fn n -> n.data.cognitive || 0 end)
    nesting_values = Enum.map(nodes, fn n -> n.data.max_nesting || 0 end)

    files_with_warnings =
      Enum.count(nodes, fn n -> length(Map.get(n.data, :warnings, [])) > 0 end)

    impure_files = Enum.count(nodes, fn n -> Map.get(n.data, :purity_pure?) == false end)

    languages =
      nodes
      |> Enum.group_by(fn n -> n.data.language end)
      |> Enum.map(fn {lang, lang_nodes} -> {lang, length(lang_nodes)} end)
      |> Enum.into(%{})

    %{
      total_files: total_files,
      avg_cyclomatic: safe_avg(cyclomatic_values),
      avg_cognitive: safe_avg(cognitive_values),
      avg_nesting: safe_avg(nesting_values),
      max_cyclomatic: Enum.max(cyclomatic_values, fn -> 0 end),
      max_cognitive: Enum.max(cognitive_values, fn -> 0 end),
      max_nesting: Enum.max(nesting_values, fn -> 0 end),
      min_cyclomatic: Enum.min(cyclomatic_values, fn -> 0 end),
      min_cognitive: Enum.min(cognitive_values, fn -> 0 end),
      min_nesting: Enum.min(nesting_values, fn -> 0 end),
      files_with_warnings: files_with_warnings,
      impure_files: impure_files,
      languages: languages
    }
  end

  defp safe_avg([]), do: 0.0

  defp safe_avg(values) do
    sum = Enum.sum(values)
    count = length(values)
    Float.round(sum / count, 2)
  end

  defp boolean_default(nil, default), do: default
  defp boolean_default(value, _default) when is_boolean(value), do: value
  defp boolean_default(_value, default), do: default
end
