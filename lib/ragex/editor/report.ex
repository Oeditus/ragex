defmodule Ragex.Editor.Report do
  @moduledoc """
  Report generation for refactoring operations.

  Generates comprehensive reports in multiple formats (Markdown, JSON, HTML)
  combining statistics, diffs, conflicts, and warnings from refactoring operations.
  """

  alias Ragex.Editor.Conflict

  @type report_format :: :markdown | :json | :html
  @type report_data :: %{
          operation: atom(),
          status: :success | :failure,
          stats: stats(),
          diffs: [map()],
          conflicts: [Conflict.conflict()],
          warnings: [String.t()],
          timing: timing_info()
        }

  @type stats :: %{
          files_modified: non_neg_integer(),
          lines_added: non_neg_integer(),
          lines_removed: non_neg_integer(),
          functions_affected: non_neg_integer()
        }

  @type timing_info :: %{
          start_time: DateTime.t(),
          end_time: DateTime.t(),
          duration_ms: non_neg_integer()
        }

  @doc """
  Generates a refactoring report in the specified format.

  ## Parameters
  - `data`: Report data including operation details, stats, diffs, and conflicts
  - `format`: Output format (:markdown, :json, or :html)
  - `opts`: Options
    - `:include_diffs` - Include full diffs (default: true)
    - `:include_conflicts` - Include conflict details (default: true)
    - `:include_timing` - Include timing information (default: true)

  ## Returns
  - `{:ok, report_string}` with formatted report
  - `{:error, reason}` on failure
  """
  @spec generate(report_data(), report_format(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate(data, format \\ :markdown, opts \\ []) do
    case format do
      :markdown -> generate_markdown(data, opts)
      :json -> generate_json(data, opts)
      :html -> generate_html(data, opts)
      _ -> {:error, "Unknown format: #{format}"}
    end
  end

  @doc """
  Creates a summary report data structure from refactor result and diffs.

  ## Parameters
  - `refactor_result`: Result from a refactoring operation
  - `diffs`: List of diff results from Diff.generate/3
  - `conflicts`: Optional list of conflicts from Conflict module

  ## Returns
  - Report data map
  """
  @spec create_report_data(map(), [map()], [Conflict.conflict()]) :: report_data()
  def create_report_data(refactor_result, diffs, conflicts \\ []) do
    stats = calculate_stats(diffs)

    %{
      operation: Map.get(refactor_result, :operation, :unknown),
      status: Map.get(refactor_result, :status, :unknown),
      stats: stats,
      diffs: diffs,
      conflicts: conflicts,
      warnings: extract_warnings(refactor_result, conflicts),
      timing: Map.get(refactor_result, :timing, %{})
    }
  end

  @doc """
  Saves a report to a file.

  ## Parameters
  - `report`: Generated report string
  - `output_path`: File path to save report

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_report(String.t(), String.t()) :: :ok | {:error, term()}
  def save_report(report, output_path) do
    File.write(output_path, report)
  end

  # Private functions - Markdown generation

  defp generate_markdown(data, opts) do
    include_diffs = Keyword.get(opts, :include_diffs, true)
    include_conflicts = Keyword.get(opts, :include_conflicts, true)
    include_timing = Keyword.get(opts, :include_timing, true)

    sections = [
      markdown_header(data),
      markdown_stats(data.stats),
      if(include_conflicts && !Enum.empty?(data.conflicts),
        do: markdown_conflicts(data.conflicts),
        else: nil
      ),
      if(Enum.empty?(data.warnings), do: nil, else: markdown_warnings(data.warnings)),
      if(include_diffs, do: markdown_diffs(data.diffs), else: nil),
      if(include_timing && data.timing != %{}, do: markdown_timing(data.timing), else: nil)
    ]

    report = sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
    {:ok, report}
  end

  defp markdown_header(data) do
    status_emoji =
      case data.status do
        :success -> "✓"
        :failure -> "✗"
        _ -> "?"
      end

    """
    # Refactoring Report: #{data.operation}

    Status: #{status_emoji} #{data.status}
    """
  end

  defp markdown_stats(stats) do
    """
    ## Statistics

    - Files Modified: #{stats.files_modified}
    - Lines Added: +#{stats.lines_added}
    - Lines Removed: -#{stats.lines_removed}
    - Functions Affected: #{stats.functions_affected}
    """
  end

  defp markdown_conflicts(conflicts) do
    conflict_list =
      Enum.map_join(conflicts, "\n", fn conflict ->
        location = format_conflict_location(conflict)
        location_part = if location != "", do: " at #{location}", else: ""
        "- **#{conflict.type}** (#{conflict.severity}): #{conflict.message}#{location_part}"
      end)

    """
    ## Conflicts Detected

    #{conflict_list}
    """
  end

  defp markdown_warnings(warnings) do
    warning_list = Enum.map_join(warnings, "\n", &"- #{&1}")

    """
    ## Warnings

    #{warning_list}
    """
  end

  defp markdown_diffs(diffs) do
    diff_sections =
      Enum.map_join(diffs, "\n", fn diff ->
        """
        ### #{diff.file_path}

        ```diff
        #{diff.unified_diff}
        ```

        Changes: +#{diff.stats.added} -#{diff.stats.removed}
        """
      end)

    """
    ## Diffs

    #{diff_sections}
    """
  end

  defp markdown_timing(timing) do
    """
    ## Timing

    - Start: #{DateTime.to_string(timing.start_time)}
    - End: #{DateTime.to_string(timing.end_time)}
    - Duration: #{timing.duration_ms}ms
    """
  end

  # Private functions - JSON generation

  defp generate_json(data, opts) do
    include_diffs = Keyword.get(opts, :include_diffs, true)
    include_conflicts = Keyword.get(opts, :include_conflicts, true)
    include_timing = Keyword.get(opts, :include_timing, true)

    json_data = %{
      operation: data.operation,
      status: data.status,
      stats: data.stats,
      warnings: data.warnings
    }

    json_data =
      if include_conflicts do
        Map.put(json_data, :conflicts, Enum.map(data.conflicts, &conflict_to_map/1))
      else
        json_data
      end

    json_data =
      if include_diffs do
        Map.put(json_data, :diffs, Enum.map(data.diffs, &diff_to_map/1))
      else
        json_data
      end

    json_data =
      if include_timing && data.timing != %{} do
        Map.put(json_data, :timing, timing_to_map(data.timing))
      else
        json_data
      end

    case Jason.encode(json_data, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "Failed to encode JSON: #{inspect(reason)}"}
    end
  end

  defp conflict_to_map(conflict) do
    %{
      type: conflict.type,
      severity: conflict.severity,
      message: conflict.message,
      file: conflict.file,
      line: conflict.line,
      location: format_conflict_location(conflict),
      suggestion: conflict.suggestion
    }
  end

  defp diff_to_map(diff) do
    %{
      file_path: diff.file_path,
      stats: diff.stats,
      unified_diff: diff.unified_diff
    }
  end

  defp timing_to_map(timing) do
    %{
      start_time: DateTime.to_iso8601(timing.start_time),
      end_time: DateTime.to_iso8601(timing.end_time),
      duration_ms: timing.duration_ms
    }
  end

  # Private functions - HTML generation

  defp generate_html(data, opts) do
    include_diffs = Keyword.get(opts, :include_diffs, true)
    include_conflicts = Keyword.get(opts, :include_conflicts, true)
    include_timing = Keyword.get(opts, :include_timing, true)

    status_class = if data.status == :success, do: "success", else: "failure"

    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>Refactoring Report: #{data.operation}</title>
      <style>
        body { font-family: sans-serif; max-width: 1200px; margin: 20px auto; padding: 0 20px; }
        h1, h2 { color: #333; }
        .status { display: inline-block; padding: 4px 12px; border-radius: 4px; font-weight: bold; }
        .status.success { background: #d4edda; color: #155724; }
        .status.failure { background: #f8d7da; color: #721c24; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin: 20px 0; }
        .stat-card { background: #f8f9fa; padding: 16px; border-radius: 4px; }
        .stat-value { font-size: 24px; font-weight: bold; color: #007bff; }
        .conflict { padding: 12px; margin: 8px 0; border-left: 4px solid; border-radius: 4px; }
        .conflict.error { background: #f8d7da; border-color: #dc3545; }
        .conflict.warning { background: #fff3cd; border-color: #ffc107; }
        .conflict.info { background: #d1ecf1; border-color: #17a2b8; }
        .diff { background: #f8f9fa; padding: 16px; border-radius: 4px; margin: 16px 0; overflow-x: auto; }
        pre { margin: 0; white-space: pre-wrap; }
        .diff-line.add { background: #e6ffed; }
        .diff-line.remove { background: #ffeef0; }
      </style>
    </head>
    <body>
      <h1>Refactoring Report: #{data.operation}</h1>
      <div class="status #{status_class}">#{data.status}</div>

      #{html_stats(data.stats)}
      #{if include_conflicts && !Enum.empty?(data.conflicts), do: html_conflicts(data.conflicts), else: ""}
      #{if Enum.empty?(data.warnings), do: "", else: html_warnings(data.warnings)}
      #{if include_diffs, do: html_diffs(data.diffs), else: ""}
      #{if include_timing && data.timing != %{}, do: html_timing(data.timing), else: ""}
    </body>
    </html>
    """

    {:ok, html}
  end

  defp html_stats(stats) do
    """
    <h2>Statistics</h2>
    <div class="stats">
      <div class="stat-card">
        <div class="stat-value">#{stats.files_modified}</div>
        <div>Files Modified</div>
      </div>
      <div class="stat-card">
        <div class="stat-value" style="color: #28a745;">+#{stats.lines_added}</div>
        <div>Lines Added</div>
      </div>
      <div class="stat-card">
        <div class="stat-value" style="color: #dc3545;">-#{stats.lines_removed}</div>
        <div>Lines Removed</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">#{stats.functions_affected}</div>
        <div>Functions Affected</div>
      </div>
    </div>
    """
  end

  defp html_conflicts(conflicts) do
    conflict_html =
      Enum.map_join(conflicts, "\n", fn conflict ->
        location = format_conflict_location(conflict)

        location_html =
          if location != "", do: "<br><code>#{html_escape(location)}</code>", else: ""

        """
        <div class="conflict #{conflict.severity}">
          <strong>#{conflict.type}</strong> (#{conflict.severity}): #{conflict.message}#{location_html}
          #{if conflict.suggestion, do: "<br><em>Suggestion: #{conflict.suggestion}</em>", else: ""}
        </div>
        """
      end)

    """
    <h2>Conflicts Detected</h2>
    #{conflict_html}
    """
  end

  defp html_warnings(warnings) do
    warning_html = Enum.map_join(warnings, "\n", &"<li>#{&1}</li>")

    """
    <h2>Warnings</h2>
    <ul>#{warning_html}</ul>
    """
  end

  defp html_diffs(diffs) do
    diff_html =
      Enum.map_join(diffs, "\n", fn diff ->
        """
        <div class="diff">
          <h3>#{diff.file_path}</h3>
          <pre>#{html_escape(diff.unified_diff)}</pre>
          <p>Changes: <span style="color: #28a745;">+#{diff.stats.added}</span> <span style="color: #dc3545;">-#{diff.stats.removed}</span></p>
        </div>
        """
      end)

    """
    <h2>Diffs</h2>
    #{diff_html}
    """
  end

  defp html_timing(timing) do
    """
    <h2>Timing</h2>
    <ul>
      <li>Start: #{DateTime.to_string(timing.start_time)}</li>
      <li>End: #{DateTime.to_string(timing.end_time)}</li>
      <li>Duration: #{timing.duration_ms}ms</li>
    </ul>
    """
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Private functions - Stats calculation

  defp calculate_stats(diffs) do
    stats =
      Enum.reduce(diffs, %{files_modified: 0, lines_added: 0, lines_removed: 0}, fn diff, acc ->
        %{
          files_modified: acc.files_modified + 1,
          lines_added: acc.lines_added + diff.stats.added,
          lines_removed: acc.lines_removed + diff.stats.removed
        }
      end)

    # Functions affected would need graph integration - placeholder for now
    Map.put(stats, :functions_affected, 0)
  end

  defp extract_warnings(refactor_result, conflicts) do
    result_warnings = Map.get(refactor_result, :warnings, [])

    conflict_warnings =
      conflicts
      |> Enum.filter(&(&1.severity == :warning))
      |> Enum.map(& &1.message)

    result_warnings ++ conflict_warnings
  end

  # Helper to format conflict location
  defp format_conflict_location(%{file: file, line: line})
       when not is_nil(file) and not is_nil(line) do
    "#{file}:#{line}"
  end

  defp format_conflict_location(%{file: file}) when not is_nil(file) do
    file
  end

  defp format_conflict_location(_), do: ""
end
