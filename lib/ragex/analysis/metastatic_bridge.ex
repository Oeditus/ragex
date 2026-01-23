defmodule Ragex.Analysis.MetastaticBridge do
  @moduledoc """
  Bridge to Metastatic analysis capabilities.

  Delegates all AST-level analysis to Metastatic's analysis modules,
  providing a unified interface for Ragex to access:
  - Complexity metrics (cyclomatic, cognitive, nesting, Halstead, LoC, function metrics)
  - Purity analysis (side effect detection)

  ## Usage

      alias Ragex.Analysis.MetastaticBridge

      # Analyze single file
      {:ok, result} = MetastaticBridge.analyze_file("lib/my_module.ex")

      # Analyze with specific metrics
      {:ok, result} = MetastaticBridge.analyze_file("lib/my_module.ex",
        metrics: [:cyclomatic, :cognitive, :purity])

      # Analyze directory
      {:ok, results} = MetastaticBridge.analyze_directory("lib/")

  ## Result Format

  Analysis results include:
  - `:path` - File path
  - `:language` - Detected language
  - `:complexity` - Complexity metrics map
  - `:purity` - Purity analysis map
  - `:warnings` - List of warning strings
  - `:timestamp` - Analysis timestamp
  """

  alias Metastatic.{Adapter, Document}
  alias Metastatic.Analysis.{Complexity, Purity}
  require Logger

  @type analysis_result :: %{
          path: String.t(),
          language: atom(),
          complexity: map(),
          purity: map(),
          warnings: [String.t()],
          timestamp: DateTime.t()
        }

  @type analysis_error :: %{
          path: String.t(),
          error: term(),
          timestamp: DateTime.t()
        }

  @supported_metrics [
    :cyclomatic,
    :cognitive,
    :nesting,
    :halstead,
    :loc,
    :function_metrics,
    :purity
  ]

  @doc """
  Returns the list of supported metrics.

  ## Examples

      iex> Ragex.Analysis.MetastaticBridge.supported_metrics()
      [:cyclomatic, :cognitive, :nesting, :halstead, :loc, :function_metrics, :purity]
  """
  @spec supported_metrics() :: [atom()]
  def supported_metrics, do: @supported_metrics

  @doc """
  Analyzes a single file for code quality metrics.

  Delegates to Metastatic for all analysis operations.

  ## Options

  - `:metrics` - List of metrics to calculate (default: all)
  - `:thresholds` - Custom threshold map for complexity warnings
  - `:language` - Explicit language (default: auto-detect)

  ## Examples

      {:ok, result} = MetastaticBridge.analyze_file("lib/my_module.ex")
      result.complexity.cyclomatic  # => 5
      result.purity.pure?           # => false
  """
  @spec analyze_file(path :: String.t(), opts :: keyword()) ::
          {:ok, analysis_result()} | {:error, term()}
  def analyze_file(path, opts \\ []) do
    metrics = Keyword.get(opts, :metrics, :all)
    thresholds = Keyword.get(opts, :thresholds, %{})
    language = Keyword.get(opts, :language, detect_language(path))

    with {:ok, content} <- File.read(path),
         {:ok, adapter} <- get_adapter(language),
         {:ok, doc} <- parse_document(adapter, content, language),
         {:ok, complexity_result} <- analyze_complexity(doc, metrics, thresholds),
         {:ok, purity_result} <- analyze_purity(doc, metrics) do
      {:ok, build_result(path, language, complexity_result, purity_result)}
    else
      {:error, reason} = error ->
        Logger.warning("Analysis failed for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Analyzes all files in a directory.

  ## Options

  - `:recursive` - Recursively analyze subdirectories (default: true)
  - `:metrics` - List of metrics to calculate (default: all)
  - `:thresholds` - Custom threshold map
  - `:parallel` - Use parallel processing (default: true)
  - `:max_concurrency` - Maximum concurrent analyses (default: System.schedulers_online())

  ## Examples

      {:ok, results} = MetastaticBridge.analyze_directory("lib/")
      Enum.each(results, fn result ->
        IO.puts("\#{result.path}: cyclomatic=\#{result.complexity.cyclomatic}")
      end)
  """
  @spec analyze_directory(path :: String.t(), opts :: keyword()) ::
          {:ok, [analysis_result()]} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    parallel = Keyword.get(opts, :parallel, true)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    case find_source_files(path, recursive) do
      {:ok, files} when files == [] ->
        {:ok, []}

      {:ok, files} ->
        results =
          if parallel do
            analyze_files_parallel(files, opts, max_concurrency)
          else
            analyze_files_sequential(files, opts)
          end

        {:ok, results}

      {:error, reason} = error ->
        Logger.error("Failed to list directory #{path}: #{inspect(reason)}")
        error
    end
  end

  # Private functions

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".rb" -> :ruby
      ".hs" -> :haskell
      # JavaScript not yet supported in Metastatic
      ".js" -> :unknown
      ".jsx" -> :unknown
      ".ts" -> :unknown
      ".tsx" -> :unknown
      ".mjs" -> :unknown
      _ -> :unknown
    end
  end

  defp get_adapter(:elixir), do: {:ok, Metastatic.Adapters.Elixir}
  defp get_adapter(:erlang), do: {:ok, Metastatic.Adapters.Erlang}
  defp get_adapter(:python), do: {:ok, Metastatic.Adapters.Python}
  defp get_adapter(:ruby), do: {:ok, Metastatic.Adapters.Ruby}
  defp get_adapter(:haskell), do: {:ok, Metastatic.Adapters.Haskell}
  defp get_adapter(lang), do: {:error, {:unsupported_language, lang}}

  defp parse_document(adapter, content, language) do
    case Adapter.abstract(adapter, content, language) do
      {:ok, %Document{} = doc} -> {:ok, doc}
      {:error, _} = error -> error
      other -> {:error, {:unexpected_parse_result, other}}
    end
  end

  defp analyze_complexity(_doc, metrics, _thresholds) when is_list(metrics) and metrics == [] do
    {:ok, nil}
  end

  defp analyze_complexity(doc, metrics, thresholds) do
    needs_complexity =
      metrics == :all or
        Enum.any?([:cyclomatic, :cognitive, :nesting, :halstead, :loc, :function_metrics], fn m ->
          m in metrics
        end)

    if needs_complexity do
      complexity_metrics = if metrics == :all, do: :all, else: filter_complexity_metrics(metrics)

      Complexity.analyze(doc, thresholds: thresholds, metrics: complexity_metrics)
    else
      {:ok, nil}
    end
  end

  defp analyze_purity(doc, metrics) when is_list(metrics) do
    if :purity in metrics do
      Purity.analyze(doc)
    else
      {:ok, nil}
    end
  end

  defp analyze_purity(doc, :all) do
    Purity.analyze(doc)
  end

  defp analyze_purity(_doc, _metrics), do: {:ok, nil}

  defp filter_complexity_metrics(metrics) do
    Enum.filter(metrics, fn m ->
      m in [:cyclomatic, :cognitive, :nesting, :halstead, :loc, :function_metrics]
    end)
  end

  defp build_result(path, language, complexity_result, purity_result) do
    %{
      path: path,
      language: language,
      complexity: format_complexity(complexity_result),
      purity: format_purity(purity_result),
      warnings: collect_warnings(complexity_result, purity_result),
      timestamp: DateTime.utc_now()
    }
  end

  defp format_complexity(nil), do: %{}

  defp format_complexity(result) do
    %{
      cyclomatic: result.cyclomatic,
      cognitive: result.cognitive,
      max_nesting: result.max_nesting,
      halstead: result.halstead,
      loc: result.loc,
      function_metrics: result.function_metrics,
      per_function: result.per_function || %{},
      summary: result.summary
    }
  end

  defp format_purity(nil), do: %{}

  defp format_purity(result) do
    %{
      pure?: result.pure?,
      effects: result.effects,
      confidence: result.confidence,
      summary: result.summary,
      unknown_calls: result.unknown_calls || []
    }
  end

  defp collect_warnings(complexity_result, purity_result) do
    complexity_warnings = if complexity_result, do: complexity_result.warnings, else: []

    purity_warnings =
      if purity_result && !purity_result.pure? do
        effects = Enum.join(purity_result.effects, ", ")
        ["Code is impure: #{effects}"]
      else
        []
      end

    complexity_warnings ++ purity_warnings
  end

  defp find_source_files(path, recursive) do
    pattern =
      if recursive do
        Path.join([path, "**", "*.{ex,exs,erl,hrl,py,rb,hs}"])
      else
        Path.join([path, "*.{ex,exs,erl,hrl,py,rb,hs}"])
      end

    files = Path.wildcard(pattern)
    {:ok, files}
  rescue
    e -> {:error, {:wildcard_failed, e}}
  end

  defp analyze_files_sequential(files, opts) do
    Enum.reduce(files, [], fn file, acc ->
      case analyze_file(file, opts) do
        {:ok, result} -> [result | acc]
        {:error, reason} -> [build_error_result(file, reason) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp analyze_files_parallel(files, opts, max_concurrency) do
    files
    |> Task.async_stream(
      fn file ->
        case analyze_file(file, opts) do
          {:ok, result} -> result
          {:error, reason} -> build_error_result(file, reason)
        end
      end,
      max_concurrency: max_concurrency,
      timeout: 30_000
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> build_error_result("unknown", {:task_exit, reason})
    end)
  end

  defp build_error_result(path, error) do
    %{
      path: path,
      language: :unknown,
      complexity: %{},
      purity: %{},
      warnings: ["Analysis failed: #{inspect(error)}"],
      timestamp: DateTime.utc_now(),
      error: error
    }
  end
end
