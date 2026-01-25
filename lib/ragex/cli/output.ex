defmodule Ragex.CLI.Output do
  @moduledoc """
  Rich output formatting utilities for tables, lists, and structured data.

  Provides functions to render tabular data, lists, and other formatted
  output for the CLI.
  """

  alias Ragex.CLI.Colors

  @type table_row :: [String.t() | number()]
  @type alignment :: :left | :right | :center

  @doc """
  Renders a table with headers and rows.

  ## Options

  - `:alignments` - List of alignments for each column (default: all :left)
  - `:borders` - Whether to draw borders (default: true)
  - `:padding` - Space between columns (default: 2)

  ## Examples

      iex> Output.table(["Name", "Age"], [["Alice", 30], ["Bob", 25]])
      # Renders:
      # Name   | Age
      # -------|-----
      # Alice  | 30
      # Bob    | 25
  """
  @spec table([String.t()], [table_row()], keyword()) :: :ok
  def table(headers, rows, opts \\ []) do
    alignments = Keyword.get(opts, :alignments, List.duplicate(:left, length(headers)))
    borders = Keyword.get(opts, :borders, true)
    padding = Keyword.get(opts, :padding, 2)

    # Convert all cells to strings
    headers = Enum.map(headers, &to_string/1)
    rows = Enum.map(rows, fn row -> Enum.map(row, &to_string/1) end)

    # Calculate column widths
    col_widths = calculate_column_widths([headers | rows])

    # Render table
    if borders do
      render_header(headers, col_widths, padding)
      render_separator(col_widths, padding)
    else
      render_row(headers, col_widths, alignments, padding, bold: true)
    end

    Enum.each(rows, fn row ->
      render_row(row, col_widths, alignments, padding)
    end)

    :ok
  end

  @doc """
  Renders a simple list with bullets.

  ## Options

  - `:bullet` - Bullet character (default: "•")
  - `:indent` - Indentation level (default: 0)
  - `:color` - Color function to apply (default: nil)

  ## Examples

      iex> Output.list(["Item 1", "Item 2", "Item 3"])
      # Renders:
      # • Item 1
      # • Item 2
      # • Item 3
  """
  @spec list([String.t()], keyword()) :: :ok
  def list(items, opts \\ []) do
    bullet = Keyword.get(opts, :bullet, "•")
    indent = Keyword.get(opts, :indent, 0)
    color_fn = Keyword.get(opts, :color)

    Enum.each(items, fn item ->
      line = String.duplicate(" ", indent) <> bullet <> " " <> item
      output = if color_fn, do: color_fn.(line), else: line
      IO.puts(output)
    end)

    :ok
  end

  @doc """
  Renders a key-value list.

  ## Options

  - `:separator` - Separator between key and value (default: ": ")
  - `:indent` - Indentation level (default: 0)
  - `:key_width` - Fixed width for keys (default: auto)
  - `:key_color` - Color for keys (default: :cyan)

  ## Examples

      iex> Output.key_value([{"Name", "Alice"}, {"Age", "30"}])
      # Renders:
      # Name: Alice
      # Age:  30
  """
  @spec key_value([{String.t(), String.t()}], keyword()) :: :ok
  def key_value(pairs, opts \\ []) do
    separator = Keyword.get(opts, :separator, ": ")
    indent = Keyword.get(opts, :indent, 0)
    key_width = Keyword.get(opts, :key_width)
    key_color = Keyword.get(opts, :key_color, :cyan)

    # Calculate max key width if not specified
    max_key_width = key_width || Enum.map(pairs, fn {k, _v} -> String.length(k) end) |> Enum.max()

    Enum.each(pairs, fn {key, value} ->
      padded_key = String.pad_trailing(key, max_key_width)
      colored_key = Colors.colorize(padded_key, key_color)
      line = String.duplicate(" ", indent) <> colored_key <> separator <> to_string(value)
      IO.puts(line)
    end)

    :ok
  end

  @doc """
  Renders a section header with optional underline.

  ## Options

  - `:underline` - Character for underline (default: "=")
  - `:color` - Color for header (default: :cyan)

  ## Examples

      iex> Output.section("Statistics")
      # Renders:
      # Statistics
      # ==========
  """
  @spec section(String.t(), keyword()) :: :ok
  def section(title, opts \\ []) do
    underline_char = Keyword.get(opts, :underline, "=")
    color = Keyword.get(opts, :color, :cyan)

    colored_title = Colors.colorize(title, color, :bright)
    IO.puts("\n" <> colored_title)

    if underline_char do
      IO.puts(String.duplicate(underline_char, String.length(title)))
    end

    IO.puts("")
    :ok
  end

  @doc """
  Renders a horizontal separator line.

  ## Options

  - `:char` - Character to use (default: "-")
  - `:width` - Line width (default: 80)
  - `:color` - Color for line (default: nil)

  ## Examples

      iex> Output.separator()
      # Renders:
      # --------------------------------------------------------------------------------
  """
  @spec separator(keyword()) :: :ok
  def separator(opts \\ []) do
    char = Keyword.get(opts, :char, "-")
    width = Keyword.get(opts, :width, 80)
    color_fn = Keyword.get(opts, :color)

    line = String.duplicate(char, width)
    output = if color_fn, do: color_fn.(line), else: line
    IO.puts(output)
    :ok
  end

  @doc """
  Renders a formatted diff with colors.

  ## Examples

      iex> Output.diff([{:add, "new line"}, {:delete, "old line"}, {:context, "same"}])
      # Renders with colors:
      # + new line (green)
      # - old line (red)
      #   same (muted)
  """
  @spec diff([{:add | :delete | :context, String.t()}]) :: :ok
  def diff(lines) do
    Enum.each(lines, fn
      {:add, text} -> IO.puts(Colors.diff_add(text))
      {:delete, text} -> IO.puts(Colors.diff_delete(text))
      {:context, text} -> IO.puts(Colors.diff_context(text))
    end)

    :ok
  end

  @doc """
  Renders a progress summary with statistics.

  ## Examples

      iex> Output.summary(%{total: 100, success: 95, errors: 5, duration: 1.5})
      # Renders formatted summary with colors
  """
  @spec summary(map()) :: :ok
  def summary(stats) do
    section("Summary")

    pairs = [
      {"Total", Map.get(stats, :total, 0)},
      {"Success", Colors.success(to_string(Map.get(stats, :success, 0)))},
      {"Errors",
       if(Map.get(stats, :errors, 0) > 0,
         do: Colors.error(to_string(Map.get(stats, :errors, 0))),
         else: "0"
       )},
      {"Duration", format_duration(Map.get(stats, :duration, 0))}
    ]

    key_value(pairs, indent: 2)
    :ok
  end

  # Private helpers

  defp calculate_column_widths(rows) do
    if Enum.empty?(rows) do
      []
    else
      num_cols = length(hd(rows))

      for col_idx <- 0..(num_cols - 1) do
        rows
        |> Enum.map(fn row -> Enum.at(row, col_idx) || "" end)
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end
    end
  end

  defp render_header(headers, widths, padding) do
    render_row(headers, widths, List.duplicate(:left, length(headers)), padding, bold: true)
  end

  defp render_separator(widths, padding) do
    sep_parts =
      Enum.map(widths, fn width ->
        String.duplicate("-", width)
      end)

    sep_line =
      Enum.join(
        sep_parts,
        String.duplicate(" ", padding - 1) <> "|" <> String.duplicate(" ", padding - 1)
      )

    IO.puts(Colors.muted(sep_line))
  end

  defp render_row(cells, widths, alignments, padding, opts \\ []) do
    bold = Keyword.get(opts, :bold, false)

    padded_cells =
      Enum.zip([cells, widths, alignments])
      |> Enum.map(fn {cell, width, alignment} ->
        pad_cell(cell, width, alignment)
      end)

    line = Enum.join(padded_cells, String.duplicate(" ", padding))
    output = if bold, do: Colors.bold(line), else: line
    IO.puts(output)
  end

  defp pad_cell(cell, width, :left), do: String.pad_trailing(cell, width)
  defp pad_cell(cell, width, :right), do: String.pad_leading(cell, width)

  defp pad_cell(cell, width, :center) do
    total_padding = width - String.length(cell)
    left_padding = div(total_padding, 2)
    right_padding = total_padding - left_padding
    String.duplicate(" ", left_padding) <> cell <> String.duplicate(" ", right_padding)
  end

  defp format_duration(seconds) when is_float(seconds) do
    cond do
      seconds < 1.0 ->
        "#{Float.round(seconds * 1000, 1)}ms"

      seconds < 60.0 ->
        "#{Float.round(seconds, 2)}s"

      true ->
        minutes = div(trunc(seconds), 60)
        secs = rem(trunc(seconds), 60)
        "#{minutes}m #{secs}s"
    end
  end

  defp format_duration(seconds) when is_integer(seconds) do
    format_duration(seconds / 1.0)
  end

  defp format_duration(_), do: "N/A"

  @doc """
  Formats a comprehensive analysis report as text.

  Takes a report map from mix ragex.analyze and formats it for display.

  ## Examples

      text = Output.format_analysis_report(report)
      IO.puts(text)
  """
  @spec format_analysis_report(map()) :: String.t()
  def format_analysis_report(report) do
    # Header box with formatted content
    header_content =
      [
        "Timestamp:      #{format_timestamp(report.timestamp)}",
        "Path:           #{report.path}",
        "Files Analyzed: #{report.files_analyzed}",
        "Entities Found: #{report.entities}"
      ]
      |> Enum.join("\n")

    header_box =
      Owl.Box.new(header_content,
        title: "Ragex Analysis Report",
        border_style: :solid_rounded,
        padding_x: 1,
        padding_y: 0
      )
      |> Owl.Data.to_chardata()
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()

    sections =
      [
        header_box,
        format_security_section(Map.get(report.results, :security)),
        format_complexity_section(Map.get(report.results, :complexity)),
        format_smells_section(Map.get(report.results, :smells)),
        format_duplicates_section(Map.get(report.results, :duplicates)),
        format_dead_code_section(Map.get(report.results, :dead_code)),
        format_dependencies_section(Map.get(report.results, :dependencies)),
        format_quality_section(Map.get(report.results, :quality))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    # Summary box at the end
    summary_box = format_summary_box(report.results)

    "\n" <> sections <> "\n\n" <> summary_box <> "\n"
  end

  defp format_timestamp(timestamp) do
    timestamp
    |> DateTime.to_string()
    |> String.replace("Z", " UTC")
  end

  defp format_security_section(nil), do: nil

  defp format_security_section(%{issues: issues}) when is_list(issues) do
    # Extract all vulnerabilities from analysis results
    all_vulns =
      Enum.flat_map(issues, fn result ->
        Map.get(result, :vulnerabilities, [])
      end)

    count = length(all_vulns)

    if count == 0 do
      success_box("Security Issues", "No security issues found")
    else
      # Group by severity
      by_severity = Enum.group_by(all_vulns, & &1.severity)

      critical = length(Map.get(by_severity, :critical, []))
      high = length(Map.get(by_severity, :high, []))
      medium = length(Map.get(by_severity, :medium, []))
      low = length(Map.get(by_severity, :low, []))

      header_text =
        Owl.Data.tag("Security Issues: #{count}", :red)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      header = [
        header_text,
        "Critical: #{critical} | High: #{high} | Medium: #{medium} | Low: #{low}"
      ]

      # Show top issues
      top_issues = all_vulns |> Enum.take(10)

      rows =
        Enum.map(top_issues, fn issue ->
          %{
            "Severity" => severity_badge(issue.severity),
            "Category" => to_string(issue.category || "Unknown"),
            "File" => Path.relative_to_cwd(issue.file),
            "Location" => format_location(issue),
            "Description" => truncate(issue.description, 60)
          }
        end)

      table_output =
        if count > 0 do
          Owl.Table.new(rows)
          |> Owl.Data.to_chardata()
          |> IO.ANSI.format()
          |> IO.iodata_to_binary()
        else
          ""
        end

      [Enum.join(header, "\n"), table_output, show_more_message(count, 10)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp format_complexity_section(nil), do: nil

  defp format_complexity_section(%{complex_functions: functions}) when is_list(functions) do
    # Filter out non-map entries (defensive)
    valid_functions = Enum.filter(functions, &is_map/1)
    count = length(valid_functions)

    if count == 0 do
      success_box("Complexity", "No overly complex functions found")
    else
      header =
        Owl.Data.tag("Complex Functions: #{count}", :yellow)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      # Show functions by complexity
      top_complex =
        valid_functions
        |> Enum.sort_by(&Map.get(&1, :cyclomatic_complexity, 0), :desc)
        |> Enum.take(15)

      rows =
        Enum.map(top_complex, fn func ->
          complexity = func.cyclomatic_complexity

          color_fn =
            cond do
              complexity >= 20 -> :red
              complexity >= 15 -> :yellow
              true -> :cyan
            end

          %{
            "Complexity" => Owl.Data.tag(to_string(complexity), color_fn),
            "Function" => "#{func.module}.#{func.name}/#{func.arity}",
            "File" => Path.relative_to_cwd(func.file || ""),
            "Location" => if(func.line, do: "Line #{func.line}", else: "")
          }
        end)

      table_output =
        Owl.Table.new(rows)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      [header, table_output, show_more_message(count, 15)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp format_smells_section(nil), do: nil

  defp format_smells_section(%{smells: %{results: results, total_smells: total}})
       when is_list(results) do
    # Extract all smells from file results
    all_smells =
      Enum.flat_map(results, fn file_result ->
        Map.get(file_result, :smells, [])
      end)

    count = total

    if count == 0 do
      success_box("Code Smells", "No code smells detected")
    else
      header =
        Owl.Data.tag("Code Smells: #{count}", :yellow)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      # Group by type
      by_type = Enum.group_by(all_smells, & &1.type)

      type_summary =
        Enum.map_join(by_type, " | ", fn {type, items} ->
          "#{type}: #{length(items)}"
        end)

      # Sort by severity (critical > high > medium > low) before taking top 12
      top_smells =
        all_smells
        |> Enum.sort_by(&smell_severity_order(&1.severity), :desc)
        |> Enum.take(12)

      rows =
        Enum.map(top_smells, fn smell ->
          location = format_smell_location_for_display(smell)

          %{
            "Type" => to_string(smell.type || "unknown"),
            "Severity" => severity_badge(smell.severity),
            "Location" => location,
            "Message" => truncate(smell.description || smell[:message] || "No description", 50)
          }
        end)

      table_output =
        Owl.Table.new(rows)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      [header, type_summary, table_output, show_more_message(count, 12)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp format_duplicates_section(nil), do: nil

  defp format_duplicates_section(%{duplicates: duplicates}) do
    count = length(duplicates)

    if count == 0 do
      success_box("Code Duplicates", "No duplicate code blocks found")
    else
      header =
        Owl.Data.tag("Duplicate Code Blocks: #{count}", :yellow)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      # Calculate stats - handle different data structures
      avg_similarity =
        if count > 0 do
          Enum.reduce(duplicates, 0.0, fn dup, acc ->
            acc + (dup[:similarity] || dup.similarity || 0.0)
          end) / count
        else
          0.0
        end

      stats =
        "Total Duplicates: #{count} | Avg Similarity: #{Float.round(avg_similarity * 100, 1)}%"

      top_duplicates = duplicates |> Enum.take(10)

      rows =
        Enum.map(top_duplicates, fn dup ->
          # Handle different duplicate data structures
          similarity = dup[:similarity] || dup.similarity || 0.0

          # Extract location information
          {_file1, _file2, loc_info} =
            case dup do
              %{file1: f1, file2: f2} ->
                {f1, f2, "#{Path.relative_to_cwd(f1)} <-> #{Path.relative_to_cwd(f2)}"}

              %{locations: locs} when is_list(locs) ->
                loc_str =
                  locs
                  |> Enum.take(2)
                  |> Enum.map_join(", ", fn loc ->
                    file = Path.relative_to_cwd(loc[:file] || loc.file || "")
                    start = loc[:start_line] || loc.start_line
                    if start, do: "#{file}:#{start}", else: file
                  end)

                loc_str = if length(locs) > 2, do: loc_str <> "...", else: loc_str
                {nil, nil, loc_str}

              _ ->
                {nil, nil, "unknown"}
            end

          clone_type = dup[:clone_type] || dup[:type] || dup.type || "unknown"

          %{
            "Type" => to_string(clone_type),
            "Similarity" => "#{Float.round(similarity * 100, 1)}%",
            "Locations" => truncate(loc_info, 80)
          }
        end)

      table_output =
        Owl.Table.new(rows)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      [header, stats, table_output, show_more_message(count, 10)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp format_dead_code_section(nil), do: nil

  defp format_dead_code_section(%{dead_functions: functions}) do
    count = length(functions)

    if count == 0 do
      success_box("Dead Code", "No dead code detected")
    else
      header =
        Owl.Data.tag("Dead Functions: #{count}", :cyan)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      # Group by module
      by_module = Enum.group_by(functions, & &1.module)
      module_summary = "Affected Modules: #{map_size(by_module)}"

      top_dead = functions |> Enum.take(15)

      rows =
        Enum.map(top_dead, fn func ->
          # Handle different dead code data structures
          {mod, name, arity, file, line} =
            case func do
              %{function: {:function, m, n, a}, metadata: meta} ->
                {m, n, a, meta[:file], meta[:line]}

              %{module: m, name: n, arity: a, file: f, line: l} ->
                {m, n, a, f, l}

              %{module: m, metadata: %{name: n, arity: a, file: f, line: l}} ->
                {m, n, a, f, l}

              _ ->
                {func[:module] || "unknown", func[:name] || "unknown", func[:arity] || 0,
                 func[:file], func[:line]}
            end

          %{
            "Function" => "#{mod}.#{name}/#{arity}",
            "File" => if(file, do: Path.relative_to_cwd(file), else: ""),
            "Location" => if(line, do: "Line #{line}", else: ""),
            "Reason" => truncate(func[:reason] || func.reason || "Never called", 40)
          }
        end)

      table_output =
        Owl.Table.new(rows)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      [header, module_summary, table_output, show_more_message(count, 15)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp format_dependencies_section(nil), do: nil

  defp format_dependencies_section(%{modules: modules}) when map_size(modules) == 0 do
    nil
  end

  defp format_dependencies_section(%{modules: modules} = data) do
    count = map_size(modules)

    header =
      Owl.Data.tag("Dependencies: #{count} modules", :cyan)
      |> Owl.Data.to_chardata()
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()

    # Show coupling metrics if available
    coupling_info =
      case data do
        %{coupling: coupling_data} when is_map(coupling_data) ->
          avg_coupling = Map.get(coupling_data, :average, 0.0)
          max_coupling = Map.get(coupling_data, :max, 0.0)
          "Avg Coupling: #{Float.round(avg_coupling, 2)} | Max: #{Float.round(max_coupling, 2)}"

        _ ->
          ""
      end

    # Show top modules by dependencies
    top_modules =
      modules
      |> Enum.map(fn {mod, info} ->
        deps = length(Map.get(info, :dependencies, []))
        {mod, deps}
      end)
      |> Enum.sort_by(fn {_, deps} -> deps end, :desc)
      |> Enum.take(10)

    if length(top_modules) > 0 do
      rows =
        Enum.map(top_modules, fn {mod, deps} ->
          %{"Module" => to_string(mod), "Dependencies" => to_string(deps)}
        end)

      table_output =
        Owl.Table.new(rows)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      [header, coupling_info, table_output]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    else
      [header, coupling_info]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp format_quality_section(nil), do: nil

  defp format_quality_section(metrics) do
    score = metrics.overall_score || 0

    color =
      cond do
        score >= 80 -> :green
        score >= 60 -> :yellow
        true -> :red
      end

    header =
      Owl.Data.tag("Quality Score: #{score}/100", color)
      |> Owl.Data.to_chardata()
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()

    # Show component scores if available
    components =
      [
        {"Maintainability", metrics[:maintainability]},
        {"Complexity", metrics[:complexity_score]},
        {"Duplication", metrics[:duplication_score]},
        {"Test Coverage", metrics[:test_coverage]},
        {"Documentation", metrics[:documentation_score]}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    if length(components) > 0 do
      rows =
        Enum.map(components, fn {name, value} ->
          score_val = if is_number(value), do: Float.round(value * 1.0, 1), else: value

          color =
            cond do
              is_number(score_val) and score_val >= 80 -> :green
              is_number(score_val) and score_val >= 60 -> :yellow
              is_number(score_val) -> :red
              true -> :white
            end

          %{"Metric" => name, "Score" => Owl.Data.tag(to_string(score_val), color)}
        end)

      table_output =
        Owl.Table.new(rows)
        |> Owl.Data.to_chardata()
        |> IO.ANSI.format()
        |> IO.iodata_to_binary()

      [header, table_output]
      |> Enum.join("\n")
    else
      header
    end
  end

  defp format_summary_box(results) do
    summary_content =
      [
        "Security Issues:   #{count_items(results, :security, :issues)}",
        "Complex Functions: #{count_items(results, :complexity, :complex_functions)}",
        "Code Smells:       #{count_smell_items(results)}",
        "Duplicate Blocks:  #{count_items(results, :duplicates, :duplicates)}",
        "Dead Functions:    #{count_items(results, :dead_code, :dead_functions)}",
        "Quality Score:     #{quality_score_display(results)}"
      ]
      |> Enum.join("\n")

    Owl.Box.new(summary_content,
      title: "Analysis Summary",
      border_style: :solid_rounded,
      padding_x: 1,
      padding_y: 0
    )
    |> Owl.Data.to_chardata()
    |> IO.ANSI.format()
    |> IO.iodata_to_binary()
  end

  defp count_items(results, type, key) do
    case Map.get(results, type) do
      nil -> 0
      data -> length(Map.get(data, key, []))
    end
  end

  defp count_smell_items(results) do
    case Map.get(results, :smells) do
      nil -> 0
      %{smells: %{total_smells: total}} -> total
      %{smells: %{smells: items}} when is_list(items) -> length(items)
      %{smells: items} when is_list(items) -> length(items)
      _ -> 0
    end
  end

  defp quality_score_display(results) do
    case Map.get(results, :quality) do
      nil -> "N/A"
      metrics -> "#{metrics.overall_score || 0}/100"
    end
  end

  defp severity_badge(:critical), do: Owl.Data.tag("CRITICAL", :red)
  defp severity_badge(:high), do: Owl.Data.tag("HIGH", :red)
  defp severity_badge(:medium), do: Owl.Data.tag("MEDIUM", :yellow)
  defp severity_badge(:low), do: Owl.Data.tag("LOW", :cyan)
  defp severity_badge(_), do: "UNKNOWN"

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 3) <> "..."
    else
      text
    end
  end

  defp truncate(text, _), do: to_string(text)

  defp show_more_message(total, shown) when total > shown do
    Owl.Data.tag("... and #{total - shown} more", :faint)
    |> Owl.Data.to_chardata()
    |> IO.ANSI.format()
    |> IO.iodata_to_binary()
  end

  defp show_more_message(_, _), do: ""

  defp success_box(title, message) do
    Owl.Box.new(Owl.Data.tag(message, :green),
      title: title,
      border_style: :solid,
      border_tag: :green,
      padding_x: 1
    )
    |> Owl.Data.to_chardata()
    |> IO.ANSI.format()
    |> IO.iodata_to_binary()
  end

  defp format_location(%{line: line, column: col}) when not is_nil(line) and not is_nil(col) do
    "Line #{line}:#{col}"
  end

  defp format_location(%{line: line}) when not is_nil(line), do: "Line #{line}"
  defp format_location(%{context: %{line: line}}) when not is_nil(line), do: "Line #{line}"
  defp format_location(_), do: ""

  # Format smell location for CLI display
  defp format_smell_location_for_display(smell) do
    case smell do
      # Try the new location format first
      %{location: %{formatted: formatted}} when is_binary(formatted) ->
        formatted

      %{location: location} when is_map(location) ->
        # Build location from components
        build_location_display_string(location)

      # Fallback to old formats
      %{location: loc} when is_binary(loc) ->
        loc

      %{file: file} when is_binary(file) ->
        file

      %{path: path} when is_binary(path) ->
        path

      _ ->
        "unknown"
    end
  end

  defp build_location_display_string(location) do
    module = Map.get(location, :module)
    function = Map.get(location, :function)
    arity = Map.get(location, :arity)
    line = Map.get(location, :line)

    cond do
      module && function && arity && line ->
        "#{inspect(module)}.#{function}/#{arity}:#{line}"

      module && function && arity ->
        "#{inspect(module)}.#{function}/#{arity}"

      function && arity && line ->
        "#{function}/#{arity}:#{line}"

      function && arity ->
        "#{function}/#{arity}"

      line ->
        "line #{line}"

      true ->
        "unknown"
    end
  end

  # Helper to get severity order for sorting (higher = more severe)
  defp smell_severity_order(:critical), do: 4
  defp smell_severity_order(:high), do: 3
  defp smell_severity_order(:medium), do: 2
  defp smell_severity_order(:low), do: 1
  defp smell_severity_order(_), do: 0
end
