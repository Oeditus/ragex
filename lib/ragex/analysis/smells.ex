defmodule Ragex.Analysis.Smells do
  @moduledoc """
  Code smell detection using Metastatic.Analysis.Smells.

  Provides file and directory-level code smell detection with configurable
  thresholds, parallel processing, and detailed reporting.

  ## Usage

      alias Ragex.Analysis.Smells

      # Analyze single file
      {:ok, result} = Smells.analyze_file("lib/my_module.ex")

      # Analyze with custom thresholds
      {:ok, result} = Smells.analyze_file("lib/my_module.ex",
        thresholds: %{max_statements: 30, max_nesting: 3})

      # Analyze directory
      {:ok, results} = Smells.analyze_directory("lib/",
        recursive: true,
        parallel: true)

      # Filter by severity
      critical = Smells.filter_by_severity(results, :critical)

  ## Detected Smells

  - **Long function** - Too many statements (default threshold: 50)
  - **Deep nesting** - Excessive nesting depth (default threshold: 4)
  - **Magic numbers** - Unexplained numeric literals
  - **Complex conditionals** - Deeply nested boolean operations
  - **Long parameter list** - Too many parameters (default threshold: 5)
  """

  require Logger
  alias Metastatic.{Adapter, Document}
  alias Metastatic.Analysis.Smells, as: MetaSmells
  alias Ragex.Analysis.LocationEnricher

  @type smell_result :: %{
          path: String.t(),
          language: atom(),
          has_smells?: boolean(),
          total_smells: non_neg_integer(),
          smells: [smell_with_location()],
          by_severity: %{atom() => non_neg_integer()},
          by_type: %{atom() => non_neg_integer()},
          summary: String.t(),
          timestamp: DateTime.t()
        }

  @type smell_with_location :: %{
          type: atom(),
          severity: atom(),
          description: String.t(),
          suggestion: String.t(),
          context: map(),
          location: location() | nil
        }

  @type location :: %{
          optional(:module) => atom(),
          optional(:function) => atom(),
          optional(:arity) => non_neg_integer(),
          optional(:line) => non_neg_integer(),
          optional(:formatted) => String.t()
        }

  @type directory_result :: %{
          total_files: non_neg_integer(),
          files_with_smells: non_neg_integer(),
          total_smells: non_neg_integer(),
          by_severity: %{atom() => non_neg_integer()},
          by_type: %{atom() => non_neg_integer()},
          results: [smell_result()],
          summary: String.t()
        }

  @default_thresholds %{
    max_statements: 50,
    max_nesting: 4,
    max_parameters: 5,
    max_cognitive: 15
  }

  @doc """
  Analyzes a single file for code smells.

  ## Options

  - `:thresholds` - Map of threshold overrides
  - `:language` - Explicit language (default: auto-detect)

  ## Examples

      {:ok, result} = Smells.analyze_file("lib/my_module.ex")
      result.has_smells?  # => true/false
      result.total_smells # => 3
  """
  @spec analyze_file(path :: String.t(), opts :: keyword()) ::
          {:ok, smell_result()} | {:error, term()}
  def analyze_file(path, opts \\ []) do
    thresholds = Keyword.get(opts, :thresholds, %{}) |> merge_thresholds()
    language = Keyword.get(opts, :language, detect_language(path))

    with {:ok, content} <- File.read(path),
         {:ok, adapter} <- get_adapter(language),
         {:ok, doc} <- parse_document(adapter, content, language),
         {:ok, result} <- MetaSmells.analyze(doc, thresholds: thresholds) do
      {:ok, format_result(path, language, result)}
    else
      {:error, reason} = error ->
        Logger.warning("Code smell analysis failed for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Analyzes all files in a directory for code smells.

  ## Options

  - `:recursive` - Recursively analyze subdirectories (default: true)
  - `:thresholds` - Map of threshold overrides
  - `:parallel` - Use parallel processing (default: true)
  - `:max_concurrency` - Maximum concurrent analyses (default: System.schedulers_online())
  - `:min_severity` - Minimum severity to include (`:low`, `:medium`, `:high`, `:critical`)

  ## Examples

      {:ok, results} = Smells.analyze_directory("lib/",
        recursive: true,
        parallel: true,
        min_severity: :medium)
  """
  @spec analyze_directory(path :: String.t(), opts :: keyword()) ::
          {:ok, directory_result()} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    parallel = Keyword.get(opts, :parallel, true)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    min_severity = Keyword.get(opts, :min_severity, :low)

    case find_source_files(path, recursive) do
      {:ok, []} ->
        {:ok, empty_directory_result()}

      {:ok, files} ->
        results =
          if parallel do
            analyze_files_parallel(files, opts, max_concurrency)
          else
            analyze_files_sequential(files, opts)
          end

        filtered_results = filter_results_by_severity(results, min_severity)
        {:ok, aggregate_results(filtered_results)}

      {:error, reason} = error ->
        Logger.error("Failed to list directory #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Filters smell results by minimum severity level.

  ## Severity Levels

  - `:low` - Include all smells
  - `:medium` - Include medium, high, and critical
  - `:high` - Include high and critical only
  - `:critical` - Include critical only

  ## Examples

      critical_smells = Smells.filter_by_severity(results, :critical)
  """
  @spec filter_by_severity([smell_result()], atom()) :: [smell_result()]
  def filter_by_severity(results, min_severity) do
    severity_levels = [:low, :medium, :high, :critical]
    min_index = Enum.find_index(severity_levels, &(&1 == min_severity)) || 0

    Enum.map(results, fn result ->
      filtered_smells =
        Enum.filter(result.smells, fn smell ->
          smell_index = Enum.find_index(severity_levels, &(&1 == smell.severity))
          smell_index >= min_index
        end)

      %{result | smells: filtered_smells, total_smells: length(filtered_smells)}
    end)
    |> Enum.reject(&(&1.total_smells == 0))
  end

  @doc """
  Filters results by smell type.

  ## Examples

      magic_numbers = Smells.filter_by_type(results, :magic_number)
  """
  @spec filter_by_type([smell_result()], atom()) :: [smell_result()]
  def filter_by_type(results, smell_type) do
    Enum.map(results, fn result ->
      filtered_smells = Enum.filter(result.smells, &(&1.type == smell_type))
      %{result | smells: filtered_smells, total_smells: length(filtered_smells)}
    end)
    |> Enum.reject(&(&1.total_smells == 0))
  end

  @doc """
  Gets default thresholds for smell detection.

  ## Examples

      iex> Ragex.Analysis.Smells.default_thresholds()
      %{max_statements: 50, max_nesting: 4, max_parameters: 5, max_cognitive: 15}
  """
  @spec default_thresholds() :: map()
  def default_thresholds, do: @default_thresholds

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

  defp merge_thresholds(overrides) do
    Map.merge(@default_thresholds, overrides)
  end

  defp format_result(path, language, result) do
    # Enrich smells with knowledge graph function context using LocationEnricher
    enriched_smells = LocationEnricher.enrich_issues(result.smells, path)

    %{
      path: path,
      language: language,
      has_smells?: result.has_smells?,
      total_smells: result.total_smells,
      smells: enriched_smells,
      by_severity: result.by_severity,
      by_type: result.by_type,
      summary: result.summary,
      timestamp: DateTime.utc_now()
    }
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
      has_smells?: false,
      total_smells: 0,
      smells: [],
      by_severity: %{},
      by_type: %{},
      summary: "Analysis failed: #{inspect(error)}",
      timestamp: DateTime.utc_now(),
      error: error
    }
  end

  defp filter_results_by_severity(results, :low), do: results

  defp filter_results_by_severity(results, min_severity) do
    filter_by_severity(results, min_severity)
  end

  defp aggregate_results(results) do
    files_with_smells = Enum.count(results, & &1.has_smells?)
    total_smells = Enum.sum(Enum.map(results, & &1.total_smells))

    by_severity =
      results
      |> Enum.flat_map(& &1.smells)
      |> Enum.reduce(%{}, fn smell, acc ->
        Map.update(acc, smell.severity, 1, &(&1 + 1))
      end)

    by_type =
      results
      |> Enum.flat_map(& &1.smells)
      |> Enum.reduce(%{}, fn smell, acc ->
        Map.update(acc, smell.type, 1, &(&1 + 1))
      end)

    %{
      total_files: length(results),
      files_with_smells: files_with_smells,
      total_smells: total_smells,
      by_severity: by_severity,
      by_type: by_type,
      results: results,
      summary: build_summary(length(results), files_with_smells, total_smells, by_severity)
    }
  end

  defp empty_directory_result do
    %{
      total_files: 0,
      files_with_smells: 0,
      total_smells: 0,
      by_severity: %{},
      by_type: %{},
      results: [],
      summary: "No files found"
    }
  end

  defp build_summary(total_files, files_with_smells, total_smells, by_severity) do
    if total_smells == 0 do
      "Analyzed #{total_files} files - no code smells detected"
    else
      severity_summary =
        by_severity
        |> Enum.sort_by(fn {sev, _} -> severity_order(sev) end, :desc)
        |> Enum.map_join(", ", fn {sev, count} -> "#{count} #{sev}" end)

      "Analyzed #{total_files} files - found #{total_smells} smell(s) in #{files_with_smells} file(s): #{severity_summary}"
    end
  end

  defp severity_order(:critical), do: 4
  defp severity_order(:high), do: 3
  defp severity_order(:medium), do: 2
  defp severity_order(:low), do: 1

  @doc """
  Detects code smells in a directory.

  Alias for `analyze_directory/2`. Provided for API consistency with mix tasks.

  ## Examples

      {:ok, smells} = Smells.detect_smells("lib/")
  """
  @spec detect_smells(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def detect_smells(path, opts \\ []), do: analyze_directory(path, opts)

  # NOTE: Legacy enrichment functions removed in favor of LocationEnricher module.
  # The LocationEnricher provides a more robust approach by:
  # 1. Extracting function names from Metastatic smell context
  # 2. Looking up functions directly from knowledge graph by name
  # 3. Falling back to line-based matching when needed
  # 4. Providing consistent formatted location strings across all analysis modules
end
