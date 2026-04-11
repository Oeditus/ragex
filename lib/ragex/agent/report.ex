defmodule Ragex.Agent.Report do
  @moduledoc """
  Report generation utilities for agent analysis.

  Handles:
  - System prompts for AI report generation (with RAG tool access)
  - Formatting raw issues for LLM consumption
  - Fallback basic report generation when no AI provider is available

  ## RAG tool access during report generation

  The system prompt returned by `system_prompt/1` permits the AI to call a
  restricted set of read-only Ragex MCP query tools while writing the report.
  This allows the AI to retrieve concrete code-level evidence (e.g. quote an
  actual function body, confirm a dependency path, or look up callers of a
  flagged function) rather than relying solely on pre-computed statistics.

  The allowed tools are the same 10 tools in `ToolSchema.rag_tool_names/0`:
  `read_file`, `semantic_search`, `hybrid_search`, `query_graph`, `list_nodes`,
  `find_callers`, `find_paths`, `find_circular_dependencies`, `coupling_report`,
  and `graph_stats`.

  Heavy re-analysis tools (`analyze_directory`, `analyze_quality`,
  `find_dead_code`, `find_duplicates`, etc.) are excluded from the tool set
  passed to the executor, so the AI cannot accidentally re-trigger the full
  analysis pipeline.
  """

  @doc """
  System prompt for report generation.

  Instructs the AI to act as a senior software architect writing a professional
  code audit report.  The AI is:

  - Given all static-analysis data in the user message as its primary source.
  - Permitted to call read-only RAG query tools (see `ToolSchema.rag_tool_names/0`)
    to retrieve concrete code evidence for specific findings.
  - Required to produce a 12-section Markdown report as its final response.

  When `project_path` is provided the prompt includes a path-constraint so
  every file-path tool argument uses the correct absolute path.

  ## Parameters

  - `project_path` - Absolute path to the project being analyzed (optional)
  """
  @spec system_prompt(String.t() | nil) :: String.t()
  def system_prompt(project_path \\ nil) do
    path_constraint =
      if project_path do
        """

        PROJECT CONTEXT:
        The project being analyzed is located at: #{project_path}
        CRITICAL: Any tool call that requires a "path" parameter MUST use exactly this path: #{project_path}
        Do NOT use ".", relative paths, parent directories, or any other path.
        """
      else
        ""
      end

    """
    You are a senior software architect conducting a professional code audit.
    Your deliverable is a comprehensive Code Quality Audit Report suitable for
    delivery to a client or code owner. Write as a professional auditor: precise,
    evidence-based, and actionable.
    #{path_constraint}
    IMPORTANT RULES:
    1. The COMPLETE analysis results are in the user message. Start writing the report
       IMMEDIATELY using that data. Do NOT claim data is missing, do NOT ask for more
       information, and do NOT call tools to re-fetch statistics already provided.
       If a section has zero findings, write "No issues detected" — that is a positive
       outcome, not missing data.
    2. As you write each section you MAY call RAG query tools to retrieve specific
       code-level evidence for individual findings — for example, to quote an actual
       function body, read a flagged file, or confirm who calls a suspicious function.
       Use tools sparingly and only when they would add concrete evidence to a specific
       claim. Allowed tools (code-level evidence only):
       - read_file: read actual source code of a flagged file
       - semantic_search: find code related to a topic by meaning
       - hybrid_search: combined semantic + graph search
       - query_graph: look up specific module/function relationships
       - list_nodes: list modules or functions by type
       - find_callers: find callers of a specific function
       - find_paths: dependency paths between two specific modules
       - find_circular_dependencies: confirm circular dependency details
       - coupling_report: coupling metrics for a specific module
       Do NOT call graph_stats — those statistics are already in the user message.
    3. Your final response must be a complete Markdown report, NOT a tool call.
    4. Never fabricate findings. If a category has zero issues, state it clearly as a positive.
    5. Every claim must be traceable to the provided data or retrieved via tools.

    REPORT STRUCTURE (mandatory sections):

    1. **Title & Metadata** -- project path, audit date, scope of analysis
    2. **Executive Summary** -- 3-5 sentence overview: overall health verdict,
       most critical finding, key metric highlights, one-line recommendation
    3. **Codebase Profile** -- architecture stats (modules, functions, edges,
       files analyzed), language breakdown, dependency density
    4. **Quality Metrics** -- cyclomatic/cognitive complexity averages & maximums,
       nesting depth, purity analysis, comparison to industry baselines
       (cyclomatic <10 = good, 10-20 = moderate, >20 = high risk;
       cognitive <15 = good, 15-30 = moderate, >30 = high risk)
    5. **Security Assessment** -- each finding with severity, CWE reference
       if available, file location, and remediation guidance
    6. **Complexity Hotspots** -- table of functions exceeding thresholds,
       with file:line, metric values, and refactoring suggestions
    7. **Code Duplication** -- clone pairs with similarity %, line counts,
       and consolidation recommendations
    8. **Dependency Analysis** -- circular dependencies, coupling concerns,
       architectural observations
    9. **Code Smells & Dead Code** -- categorized findings with locations
    10. **Refactoring Roadmap** -- prioritized action items grouped into:
        - Immediate (< 1 day): security fixes, critical bugs
        - Short-term (1-5 days): complexity reduction, duplication removal
        - Medium-term (1-4 weeks): architectural improvements
        Each item with estimated effort and expected impact.
    11. **Overall Health Score** -- rate 1-10 with justification, broken down by:
        security, complexity, maintainability, architecture
    12. **Appendix** -- methodology notes, tools used, thresholds applied

    STYLE GUIDELINES:
    - Be specific: cite file paths, line numbers, function names
    - Quantify everything: "3 of 12 functions exceed threshold" not "some functions are complex"
    - For zero-issue categories, explicitly state: "No issues detected" (this is valuable signal)
    - Use tables for structured data (complexity hotspots, security findings)
    - Provide concrete code-level recommendations, not generic advice
    - Keep the tone professional and objective -- no filler, no superlatives
    - Estimate effort in person-hours or person-days
    """
  end

  @doc """
  Format issues map for LLM consumption.
  """
  @spec format_issues_for_llm(map()) :: String.t()
  def format_issues_for_llm(issues) when is_map(issues) do
    sections = [
      format_quality_overview(issues[:quality_metrics]),
      format_section("Dead Code", issues[:dead_code], &format_dead_code/1),
      format_section("Code Duplicates", issues[:duplicates], &format_duplicate/1),
      format_section(
        "Security Vulnerabilities",
        flatten_security_results(issues[:security]),
        &format_security/1
      ),
      format_section("Code Smells", flatten_smell_results(issues[:smells]), &format_smell/1),
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
    category = item[:category] || item[:type] || item["type"] || item[:vulnerability] || "issue"
    file = item[:file] || item["file"] || "unknown"
    context = item[:context] || %{}
    line = item[:line] || item["line"] || context[:line] || "?"
    desc = item[:description] || item["description"] || item[:message] || ""
    cwe = item[:cwe] || item["cwe"]
    recommendation = item[:recommendation] || item["recommendation"]

    severity_label =
      case severity do
        s when s in ["critical", :critical] -> "[CRITICAL]"
        s when s in ["high", :high] -> "[HIGH]"
        s when s in ["medium", :medium] -> "[MEDIUM]"
        _ -> "[LOW]"
      end

    cwe_ref = if cwe, do: " (CWE-#{cwe})", else: ""
    rec_text = if recommendation, do: " -- #{recommendation}", else: ""

    "- #{severity_label} **#{category}**#{cwe_ref} in `#{file}:#{line}`: #{desc}#{rec_text}"
  end

  defp format_security(item), do: "- #{inspect(item)}"

  defp format_smell(item) when is_map(item) do
    type = item[:type] || item["type"] || item[:smell] || "smell"
    file = item[:file] || item["file"] || item[:path] || "unknown"
    context = item[:context] || %{}
    location = item[:location] || %{}
    line = item[:line] || item["line"] || location[:line] || context[:line] || "?"
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

  defp format_quality_overview(nil), do: nil
  defp format_quality_overview(metrics) when metrics == %{}, do: nil

  defp format_quality_overview(metrics) when is_map(metrics) do
    total = Map.get(metrics, :total_files, 0)

    if total == 0 do
      nil
    else
      avg_cyc = round_metric(metrics[:avg_cyclomatic])
      avg_cog = round_metric(metrics[:avg_cognitive])
      max_cyc = metrics[:max_cyclomatic] || 0
      max_cog = metrics[:max_cognitive] || 0
      avg_nest = round_metric(metrics[:avg_nesting])
      impure = metrics[:impure_files] || 0
      warnings = metrics[:files_with_warnings] || 0

      """
      ### Quality Metrics Overview (#{total} files analyzed)

      - Average cyclomatic complexity: #{avg_cyc}
      - Average cognitive complexity: #{avg_cog}
      - Max cyclomatic complexity: #{max_cyc}
      - Max cognitive complexity: #{max_cog}
      - Average nesting depth: #{avg_nest}
      - Files with side effects: #{impure}
      - Files with warnings: #{warnings}
      """
    end
  end

  defp format_quality_overview(_), do: nil

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

    quality = issues[:quality_metrics] || %{}
    files_analyzed = Map.get(quality, :total_files, 0)

    total =
      counts.dead_code + counts.duplicates + counts.security +
        counts.smells + counts.complexity + counts.circular_deps

    """
    | Category | Count |
    |----------|-------|
    | Files Analyzed (quality) | #{files_analyzed} |
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

  # Flatten per-file security analysis_result maps into individual vulnerability maps.
  # Security.analyze_directory/2 returns [{file, vulnerabilities, ...}] where each
  # vulnerability carries :category, :severity, :cwe, :context (with :line/:col), etc.
  defp flatten_security_results(nil), do: nil
  defp flatten_security_results([]), do: []

  defp flatten_security_results(results) when is_list(results) do
    Enum.flat_map(results, fn
      %{vulnerabilities: vulns, file: file} when is_list(vulns) ->
        Enum.map(vulns, fn vuln -> Map.put_new(vuln, :file, file) end)

      # Already a flat vulnerability or unknown shape -- pass through
      other ->
        [other]
    end)
  end

  # Flatten directory_result map (from Smells.detect_smells) into individual smell maps.
  # The directory_result has shape %{results: [%{path, smells: [...], ...}]}.
  defp flatten_smell_results(nil), do: nil
  defp flatten_smell_results([]), do: []
  defp flatten_smell_results(items) when is_list(items), do: items

  defp flatten_smell_results(%{results: results}) when is_list(results) do
    Enum.flat_map(results, fn
      %{smells: smells, path: path} when is_list(smells) ->
        Enum.map(smells, fn smell -> Map.put_new(smell, :file, path) end)

      other ->
        [other]
    end)
  end

  defp flatten_smell_results(_other), do: nil

  defp round_metric(nil), do: 0
  defp round_metric(val) when is_float(val), do: Float.round(val, 1)
  defp round_metric(val) when is_integer(val), do: val
  defp round_metric(_), do: 0

  defp count_items(nil), do: 0
  defp count_items(items) when is_list(items), do: length(items)
  defp count_items(%{items: items}) when is_list(items), do: length(items)
  defp count_items(_), do: 0
end
