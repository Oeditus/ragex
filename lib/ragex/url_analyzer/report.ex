defmodule Ragex.URLAnalyzer.Report do
  @moduledoc """
  Constructs standardized machine-understandable JSON reports and Markdown summaries.
  """

  @doc """
  Builds a unified machine-understandable report map from analysis results.
  """
  @spec build_report(String.t(), atom(), map(), keyword()) :: {:ok, map()}
  def build_report(url, target_type, raw_analysis, opts \\ []) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    indexed_in_graph = Keyword.get(opts, :index_graph, true)

    {metadata, summary, architecture, metrics} = extract_sections(target_type, raw_analysis)

    report_map = %{
      schema: "ragex.url_analysis.v1",
      url: url,
      target_type: to_string(target_type),
      analyzed_at: timestamp,
      indexed_in_graph: indexed_in_graph,
      metadata: metadata,
      summary: summary,
      architecture_or_structure: architecture,
      quality_and_metrics: metrics,
      raw_data_summary: extract_raw_summary(raw_analysis)
    }

    markdown_summary = generate_markdown(report_map)

    {:ok, Map.put(report_map, :human_readable_report, markdown_summary)}
  end

  defp extract_sections(:git_repo, analysis) do
    metadata = analysis[:git_metadata] || %{}
    summary = analysis[:summary] || %{}
    architecture = analysis[:architecture] || %{}
    metrics = analysis[:quality_and_metrics] || %{}

    readme_excerpt = analysis[:readme]

    summary =
      if readme_excerpt,
        do: Map.put(summary, :readme_excerpt, String.slice(readme_excerpt, 0, 500)),
        else: summary

    {metadata, summary, architecture, metrics}
  end

  defp extract_sections(_type, analysis) do
    metadata = analysis[:metadata] || %{}
    summary = analysis[:summary] || %{}

    architecture = %{
      headings: analysis[:headings] || [],
      code_blocks: analysis[:code_blocks] || [],
      links: analysis[:links] || []
    }

    metrics = %{
      http_status: analysis[:http_status] || 200,
      content_type: analysis[:content_type] || "text/html"
    }

    {metadata, summary, architecture, metrics}
  end

  defp extract_raw_summary(analysis) do
    case analysis[:extracted_text] do
      nil -> nil
      text -> String.slice(text, 0, 1000)
    end
  end

  @doc """
  Renders a clean GitHub-style Markdown report.
  """
  @spec generate_markdown(map()) :: String.t()
  def generate_markdown(report) do
    """
    # 🌐 URL Analysis Report: #{report.url}

    - **Target Type:** `#{report.target_type}`
    - **Analyzed At:** `#{report.analyzed_at}`
    - **Graph Indexed:** `#{report.indexed_in_graph}`

    ## 📊 Summary
    #{format_map(report.summary)}

    ## 🏗️ Architecture / Structure
    #{format_map(report.architecture_or_structure)}

    ## 📈 Quality & Metrics
    #{format_map(report.quality_and_metrics)}
    """
  end

  defp format_map(map) when is_map(map) do
    Enum.map_join(map, "\n", fn {k, v} -> "- **#{k}:** #{inspect(v)}" end)
  end

  defp format_map(other), do: inspect(other)
end
