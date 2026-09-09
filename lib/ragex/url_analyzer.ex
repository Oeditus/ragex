defmodule Ragex.URLAnalyzer do
  @moduledoc """
  Unified URL analysis tool for Ragex.

  Accepts any URL target (Git repository, web page, API specification, or raw code file),
  classifies the target, performs deep analysis, indexes content into the Ragex knowledge
  graph, and outputs a machine-understandable report.
  """

  alias Ragex.Graph.Store
  alias Ragex.URLAnalyzer.{Classifier, GitFetcher, Report, WebFetcher}

  require Logger

  @doc """
  Analyzes a target URL and returns a machine-understandable report map.

  ## Options

  - `:auth_token` - Authentication token (e.g., GitHub/GitLab API token)
  - `:depth` - Shallow clone depth for Git repositories (default: 1)
  - `:index_graph` - Whether to index findings into Ragex Graph Store (default: true)
  """
  @spec analyze(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(url, opts \\ []) when is_binary(url) do
    with {:ok, target_type, _meta} <- Classifier.classify(url),
         {:ok, raw_analysis} <- fetch_and_analyze(url, target_type, opts),
         {:ok, report} <- Report.build_report(url, target_type, raw_analysis, opts) do
      if Keyword.get(opts, :index_graph, true) do
        index_report_into_graph(report)
      end

      {:ok, report}
    else
      {:error, reason} ->
        Logger.error("URL analysis failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_and_analyze(url, :git_repo, opts) do
    GitFetcher.analyze_repository(url, opts)
  end

  defp fetch_and_analyze(url, _other_type, opts) do
    WebFetcher.fetch_and_parse(url, opts)
  end

  defp index_report_into_graph(report) do
    node_id = "url:#{report.url}"

    properties = %{
      url: report.url,
      target_type: report.target_type,
      analyzed_at: report.analyzed_at,
      title: report.metadata[:title] || report.url,
      summary: Jason.encode!(report.summary)
    }

    try do
      if Code.ensure_loaded?(Store) do
        Store.add_node(:url_resource, node_id, properties)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
