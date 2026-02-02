defmodule Ragex.Analysis.Security do
  @moduledoc """
  Security vulnerability analysis using Metastatic.

  Detects security vulnerabilities including:
  - Injection attacks (SQL, command, code injection)
  - Unsafe deserialization (eval, exec, pickle.loads)
  - Hardcoded secrets (API keys, passwords)
  - Weak cryptography (MD5, SHA1, DES)
  - Insecure protocols (HTTP URLs)

  ## Usage

      alias Ragex.Analysis.Security
      
      # Analyze single file
      {:ok, result} = Security.analyze_file("lib/my_module.ex")
      
      # Check for vulnerabilities
      result.has_vulnerabilities?  # => true/false
      result.total_vulnerabilities # => 3
      result.critical_count        # => 1
      
      # Analyze directory
      {:ok, results} = Security.analyze_directory("lib/")
      
      # Generate audit report
      report = Security.audit_report(results)
  """

  alias Metastatic.{Adapter, Document}
  alias Metastatic.Analysis.Security, as: MetaSecurity
  alias Ragex.Analysis.{ASTLocationExtractor, LocationPreservation}
  require Logger

  @type vulnerability :: %{
          category: atom(),
          severity: :critical | :high | :medium | :low,
          description: String.t(),
          recommendation: String.t(),
          cwe: non_neg_integer() | nil,
          context: map(),
          file: String.t(),
          language: atom()
        }

  @type analysis_result :: %{
          file: String.t(),
          language: atom(),
          vulnerabilities: [vulnerability()],
          has_vulnerabilities?: boolean(),
          total_vulnerabilities: non_neg_integer(),
          critical_count: non_neg_integer(),
          high_count: non_neg_integer(),
          medium_count: non_neg_integer(),
          low_count: non_neg_integer(),
          timestamp: DateTime.t()
        }

  @doc """
  Analyzes a single file for security vulnerabilities.

  ## Options

  - `:categories` - List of vulnerability categories to check (default: all)
  - `:min_severity` - Minimum severity to report (default: :low)
  - `:language` - Explicit language (default: auto-detect)

  ## Examples

      {:ok, result} = Security.analyze_file("lib/my_module.ex")
      result.has_vulnerabilities?  # => false
  """
  @spec analyze_file(String.t(), keyword()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze_file(path, opts \\ []) do
    language = Keyword.get(opts, :language, detect_language(path))

    with {:ok, content} <- File.read(path),
         # Phase 1: Extract native AST locations BEFORE Metastatic transformation
         {:ok, location_map} <- ASTLocationExtractor.extract_from_content(content, language),
         {:ok, adapter} <- get_adapter(language),
         {:ok, doc} <- parse_document(adapter, content, language),
         {:ok, meta_result} <- MetaSecurity.analyze(doc, opts) do
      # Phase 2: Build result with location preservation
      result = build_result(path, language, meta_result, location_map)
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.warning("Security analysis failed for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Analyzes all files in a directory for security vulnerabilities.

  ## Options

  - `:recursive` - Recursively analyze subdirectories (default: true)
  - `:parallel` - Use parallel processing (default: true)
  - `:max_concurrency` - Maximum concurrent analyses (default: System.schedulers_online())
  - Plus all options from `analyze_file/2`

  ## Examples

      {:ok, results} = Security.analyze_directory("lib/")
      total_vulns = Enum.sum(Enum.map(results, & &1.total_vulnerabilities))
  """
  @spec analyze_directory(String.t(), keyword()) :: {:ok, [analysis_result()]} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    parallel = Keyword.get(opts, :parallel, true)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    case find_source_files(path, recursive) do
      {:ok, []} ->
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

  @doc """
  Scans a directory for security vulnerabilities.

  Alias for `analyze_directory/2`. Provided for API consistency.

  ## Examples

      {:ok, results} = Security.scan_directory("lib/", severity: [:high, :critical])
  """
  @spec scan_directory(String.t(), keyword()) :: {:ok, [analysis_result()]} | {:error, term()}
  def scan_directory(path, opts \\ []), do: analyze_directory(path, opts)

  @doc """
  Generates a comprehensive security audit report.

  Returns a formatted map with:
  - Summary statistics
  - Vulnerabilities grouped by severity
  - Vulnerabilities grouped by category
  - Recommendations

  ## Examples

      {:ok, results} = Security.analyze_directory("lib/")
      report = Security.audit_report(results)
      IO.puts(report.summary)
  """
  @spec audit_report([analysis_result()]) :: map()
  def audit_report(results) when is_list(results) do
    all_vulns = Enum.flat_map(results, & &1.vulnerabilities)

    %{
      summary: build_summary(results, all_vulns),
      by_severity: group_by_severity(all_vulns),
      by_category: group_by_category(all_vulns),
      by_file: group_by_file(results),
      recommendations: generate_recommendations(all_vulns),
      total_files: length(results),
      files_with_vulnerabilities: Enum.count(results, & &1.has_vulnerabilities?),
      timestamp: DateTime.utc_now()
    }
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

  defp build_result(path, language, meta_result, location_map) do
    vulns =
      meta_result.vulnerabilities
      |> Enum.map(fn vuln ->
        Map.merge(vuln, %{file: path, language: language})
      end)
      # Phase 2: First try native AST locations, then fallback to graph enrichment
      |> LocationPreservation.merge_locations(location_map, path)

    severity_counts = count_by_severity(vulns)

    %{
      file: path,
      language: language,
      vulnerabilities: vulns,
      has_vulnerabilities?: meta_result.has_vulnerabilities?,
      total_vulnerabilities: meta_result.total_vulnerabilities,
      critical_count: Map.get(severity_counts, :critical, 0),
      high_count: Map.get(severity_counts, :high, 0),
      medium_count: Map.get(severity_counts, :medium, 0),
      low_count: Map.get(severity_counts, :low, 0),
      timestamp: DateTime.utc_now()
    }
  end

  defp count_by_severity(vulnerabilities) do
    Enum.reduce(vulnerabilities, %{}, fn vuln, acc ->
      Map.update(acc, vuln.severity, 1, &(&1 + 1))
    end)
  end

  defp find_source_files(path, recursive) do
    extensions = [".ex", ".exs", ".erl", ".hrl", ".py", ".rb"]

    try do
      files =
        if recursive do
          Path.wildcard(Path.join(path, "**/*"))
        else
          Path.wildcard(Path.join(path, "*"))
        end
        |> Enum.filter(fn file ->
          File.regular?(file) and Path.extname(file) in extensions
        end)

      {:ok, files}
    rescue
      e -> {:error, e}
    end
  end

  defp analyze_files_parallel(files, opts, max_concurrency) do
    files
    |> Task.async_stream(
      fn file -> analyze_file(file, opts) end,
      max_concurrency: max_concurrency,
      timeout: 30_000
    )
    |> Enum.reduce([], fn
      {:ok, {:ok, result}}, acc -> [result | acc]
      {:ok, {:error, _reason}}, acc -> acc
      {:exit, _reason}, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp analyze_files_sequential(files, opts) do
    Enum.reduce(files, [], fn file, acc ->
      case analyze_file(file, opts) do
        {:ok, result} -> [result | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_summary(results, all_vulns) do
    total_files = length(results)
    files_with_vulns = Enum.count(results, & &1.has_vulnerabilities?)
    total_vulns = length(all_vulns)

    severity_counts = count_by_severity(all_vulns)
    critical = Map.get(severity_counts, :critical, 0)
    high = Map.get(severity_counts, :high, 0)
    medium = Map.get(severity_counts, :medium, 0)
    low = Map.get(severity_counts, :low, 0)

    status =
      cond do
        critical > 0 -> "CRITICAL - Immediate action required"
        high > 0 -> "HIGH RISK - Action recommended"
        medium > 0 -> "MEDIUM RISK - Review recommended"
        low > 0 -> "LOW RISK - Minor issues found"
        true -> "PASSED - No vulnerabilities detected"
      end

    """
    Security Audit Summary
    =====================

    Status: #{status}

    Files Analyzed: #{total_files}
    Files with Vulnerabilities: #{files_with_vulns}
    Total Vulnerabilities: #{total_vulns}

    Severity Breakdown:
    - Critical: #{critical}
    - High: #{high}
    - Medium: #{medium}
    - Low: #{low}
    """
  end

  defp group_by_severity(vulnerabilities) do
    Enum.group_by(vulnerabilities, & &1.severity)
    |> Enum.map(fn {severity, vulns} ->
      {severity, Enum.sort_by(vulns, & &1.file)}
    end)
    |> Map.new()
  end

  defp group_by_category(vulnerabilities) do
    Enum.group_by(vulnerabilities, & &1.category)
    |> Enum.map(fn {category, vulns} ->
      {category, Enum.sort_by(vulns, & &1.severity, :desc)}
    end)
    |> Map.new()
  end

  defp group_by_file(results) do
    results
    |> Enum.filter(& &1.has_vulnerabilities?)
    |> Enum.map(fn result ->
      {result.file, result.vulnerabilities}
    end)
    |> Map.new()
  end

  defp generate_recommendations(vulnerabilities) do
    vulnerabilities
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, vulns} ->
      count = length(vulns)
      severity = Enum.max_by(vulns, &severity_level/1).severity

      %{
        category: category,
        count: count,
        severity: severity,
        recommendation: get_category_recommendation(category, count)
      }
    end)
    |> Enum.sort_by(&severity_level(&1), :desc)
  end

  defp severity_level(%{severity: severity}), do: severity_level(severity)

  defp severity_level(:critical), do: 4
  defp severity_level(:high), do: 3
  defp severity_level(:medium), do: 2
  defp severity_level(:low), do: 1

  defp get_category_recommendation(:unsafe_deserialization, count) do
    "Found #{count} unsafe deserialization issue(s). Never use eval/exec on untrusted input. Consider using safe alternatives like JSON parsing."
  end

  defp get_category_recommendation(:injection, count) do
    "Found #{count} potential injection vulnerability(ies). Always sanitize and validate user input. Use parameterized queries for databases."
  end

  defp get_category_recommendation(:hardcoded_secret, count) do
    "Found #{count} hardcoded secret(s). Move all secrets to environment variables or secure vaults (e.g., HashiCorp Vault, AWS Secrets Manager)."
  end

  defp get_category_recommendation(:weak_cryptography, count) do
    "Found #{count} weak cryptography usage(s). Replace MD5/SHA1 with SHA-256 or better. Use bcrypt/argon2 for passwords."
  end

  defp get_category_recommendation(:insecure_protocol, count) do
    "Found #{count} insecure protocol usage(s). Replace HTTP with HTTPS for all external communications."
  end

  defp get_category_recommendation(category, count) do
    "Found #{count} #{category} issue(s). Review and address these security concerns."
  end
end
