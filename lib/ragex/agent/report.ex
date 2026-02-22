defmodule Ragex.Agent.Report do
  @moduledoc """
  Report generation utilities for agent analysis.

  Handles:
  - Formatting raw issues for LLM consumption
  - System prompts for report generation
  - Fallback basic report generation
  """

  @doc """
  System prompt for report generation.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are an expert code reviewer and software architect. Your task is to analyze
    code quality findings and produce clear, actionable reports.

    Guidelines:
    - Prioritize issues by severity (critical > high > medium > low)
    - Be specific about locations (file paths, line numbers)
    - Provide concrete recommendations, not vague suggestions
    - Group related issues together
    - Use clear, professional language
    - Include code examples where helpful
    - Estimate effort for fixes (quick fix, moderate, significant refactoring)

    Output Format:
    Use Markdown formatting with clear sections and bullet points.
    """
  end

  @doc """
  Format issues map for LLM consumption.
  """
  @spec format_issues_for_llm(map()) :: String.t()
  def format_issues_for_llm(issues) when is_map(issues) do
    sections = [
      format_section("Dead Code", issues[:dead_code], &format_dead_code/1),
      format_section("Code Duplicates", issues[:duplicates], &format_duplicate/1),
      format_section("Security Issues", issues[:security], &format_security/1),
      format_section("Code Smells", issues[:smells], &format_smell/1),
      format_section("High Complexity", issues[:complexity], &format_complexity/1),
      format_section("Circular Dependencies", issues[:circular_deps], &format_circular_dep/1),
      format_section("Refactoring Suggestions", issues[:suggestions], &format_suggestion/1)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  def format_issues_for_llm(_), do: "No issues data available."

  @doc """
  Generate a basic report without AI assistance.

  Used as fallback when AI generation fails.
  """
  @spec generate_basic_report(map()) :: String.t()
  def generate_basic_report(issues) when is_map(issues) do
    """
    # Code Analysis Report

    Generated: #{DateTime.utc_now() |> DateTime.to_string()}

    ## Summary

    #{generate_summary_section(issues)}

    ## Detailed Findings

    #{format_issues_for_llm(issues)}

    ## Recommendations

    Based on the analysis, consider addressing issues in the following order:
    1. Security vulnerabilities (if any)
    2. Critical bugs and dead code
    3. High complexity functions
    4. Code duplicates
    5. Code smells and style issues

    ---
    *Note: This is an automated report. For detailed AI-powered analysis,
    ensure an AI provider is configured.*
    """
  end

  def generate_basic_report(_) do
    """
    # Code Analysis Report

    No issues were found or analysis data was unavailable.

    Generated: #{DateTime.utc_now() |> DateTime.to_string()}
    """
  end

  # Private functions

  defp format_section(_title, nil, _formatter), do: nil
  defp format_section(_title, [], _formatter), do: nil

  defp format_section(title, items, formatter) when is_list(items) do
    formatted_items =
      items
      |> Enum.take(50)
      |> Enum.map_join("\n", formatter)

    truncation_notice =
      if length(items) > 50 do
        "\n\n*... and #{length(items) - 50} more items*"
      else
        ""
      end

    """
    ### #{title} (#{length(items)} found)

    #{formatted_items}#{truncation_notice}
    """
  end

  defp format_section(title, %{items: items}, formatter) when is_list(items) do
    format_section(title, items, formatter)
  end

  defp format_section(_title, _other, _formatter), do: nil

  defp format_dead_code(item) when is_map(item) do
    file = item[:file] || item["file"] || "unknown"
    name = item[:name] || item["name"] || format_function(item[:function]) || "unknown"
    line = item[:line] || item["line"] || "?"
    reason = item[:reason] || item["reason"] || "unused"

    "- `#{name}` in `#{file}:#{line}` → #{reason}"
  end

  defp format_dead_code(item), do: "- #{inspect(item)}"

  defp format_function(nil), do: nil
  defp format_function(fun) when is_binary(fun), do: fun

  defp format_function(%{arity: arity, module: module, name: name, type: :function}),
    do: module |> Function.capture(name, arity) |> inspect() |> String.trim_leading("&")

  defp format_duplicate(item) when is_map(item) do
    file1 = item[:file1] || item["file1"] || item[:source] || "file1"
    file2 = item[:file2] || item["file2"] || item[:target] || "file2"
    similarity = item[:similarity] || item["similarity"] || 0
    lines = item[:lines] || item["lines"] || "?"

    sim_percent =
      if is_number(similarity), do: "#{round(similarity * 100)}%", else: "#{similarity}"

    "- #{sim_percent} similar: `#{file1}` and `#{file2}` (#{lines} lines)"
  end

  defp format_duplicate(item), do: "- #{inspect(item)}"

  defp format_security(item) when is_map(item) do
    severity = item[:severity] || item["severity"] || "unknown"
    type = item[:type] || item["type"] || item[:vulnerability] || "issue"
    file = item[:file] || item["file"] || "unknown"
    line = item[:line] || item["line"] || "?"
    desc = item[:description] || item["description"] || item[:message] || ""

    severity_emoji =
      case severity do
        s when s in ["critical", :critical] -> "[CRITICAL]"
        s when s in ["high", :high] -> "[HIGH]"
        s when s in ["medium", :medium] -> "[MEDIUM]"
        _ -> "[LOW]"
      end

    "- #{severity_emoji} **#{type}** in `#{file}:#{line}`: #{desc}"
  end

  defp format_security(item), do: "- #{inspect(item)}"

  defp format_smell(item) when is_map(item) do
    type = item[:type] || item["type"] || item[:smell] || "smell"
    file = item[:file] || item["file"] || "unknown"
    line = item[:line] || item["line"] || "?"
    message = item[:message] || item["message"] || item[:description] || ""

    "- **#{type}** in `#{file}:#{line}`: #{message}"
  end

  defp format_smell(item), do: "- #{inspect(item)}"

  defp format_complexity(item) when is_map(item) do
    func = item[:function] || item["function"] || item[:name] || "function"
    file = item[:file] || item["file"] || "unknown"
    line = item[:line] || item["line"] || "?"
    cyclomatic = item[:cyclomatic] || item["cyclomatic"] || item[:complexity] || "?"
    cognitive = item[:cognitive] || item["cognitive"]

    complexity_str =
      if cognitive do
        "cyclomatic: #{cyclomatic}, cognitive: #{cognitive}"
      else
        "complexity: #{cyclomatic}"
      end

    "- `#{func}` in `#{file}:#{line}` - #{complexity_str}"
  end

  defp format_complexity(item), do: "- #{inspect(item)}"

  defp format_circular_dep(item) when is_map(item) do
    cycle = item[:cycle] || item["cycle"] || item[:modules] || []

    cycle_str =
      case cycle do
        modules when is_list(modules) -> Enum.join(modules, " -> ")
        str when is_binary(str) -> str
        _ -> inspect(cycle)
      end

    "- Cycle: #{cycle_str}"
  end

  defp format_circular_dep(item) when is_list(item) do
    "- Cycle: #{Enum.join(item, " -> ")}"
  end

  defp format_circular_dep(item), do: "- #{inspect(item)}"

  defp format_suggestion(item) when is_map(item) do
    type = item[:type] || item["type"] || item[:pattern] || "suggestion"
    priority = item[:priority] || item["priority"] || "medium"
    target = item[:target] || item["target"] || item[:file] || "unknown"
    reason = item[:reason] || item["reason"] || item[:description] || ""

    priority_label =
      case priority do
        p when p in ["high", :high, 1, 2] -> "[HIGH]"
        p when p in ["low", :low, 4, 5] -> "[LOW]"
        _ -> "[MEDIUM]"
      end

    "- #{priority_label} **#{type}** for `#{target}`: #{reason}"
  end

  defp format_suggestion(item), do: "- #{inspect(item)}"

  defp generate_summary_section(issues) do
    counts = %{
      dead_code: count_items(issues[:dead_code]),
      duplicates: count_items(issues[:duplicates]),
      security: count_items(issues[:security]),
      smells: count_items(issues[:smells]),
      complexity: count_items(issues[:complexity]),
      circular_deps: count_items(issues[:circular_deps]),
      suggestions: count_items(issues[:suggestions])
    }

    total =
      counts.dead_code + counts.duplicates + counts.security +
        counts.smells + counts.complexity + counts.circular_deps

    """
    | Category | Count |
    |----------|-------|
    | Dead Code | #{counts.dead_code} |
    | Duplicates | #{counts.duplicates} |
    | Security Issues | #{counts.security} |
    | Code Smells | #{counts.smells} |
    | High Complexity | #{counts.complexity} |
    | Circular Dependencies | #{counts.circular_deps} |
    | **Total Issues** | **#{total}** |
    | Refactoring Suggestions | #{counts.suggestions} |
    """
  end

  defp count_items(nil), do: 0
  defp count_items(items) when is_list(items), do: length(items)
  defp count_items(%{items: items}) when is_list(items), do: length(items)
  defp count_items(_), do: 0
end
