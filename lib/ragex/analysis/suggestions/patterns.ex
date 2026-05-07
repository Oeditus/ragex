defmodule Ragex.Analysis.Suggestions.Patterns do
  @moduledoc """
  Pattern detection for common refactoring opportunities.

  Detects 9 patterns:
  1. **Extract Function** - Long functions, duplicate code blocks
  2. **Inline Function** - Single-use functions, trivial wrappers
  3. **Split Module** - God modules, low cohesion
  4. **Merge Modules** - Similar modules, related functionality
  5. **Remove Dead Code** - Unused functions, unreachable code
  6. **Reduce Coupling** - High-coupling modules, circular dependencies
  7. **Simplify Complexity** - High cyclomatic complexity, deep nesting
  8. **Extract Module** - Related functions in different modules
  9. **Introduce FSM** - Imperative status management (suggests Finitomata/gen_statem)

  Each detector returns suggestions with:
  - Pattern type
  - Confidence score (0.0-1.0)
  - Target location
  - Reason/justification
  - Relevant metrics
  """

  @complexity_threshold_high 15
  @loc_threshold_long 50
  @loc_threshold_medium 30
  @module_function_count_threshold 30
  @coupling_threshold 0.8
  @duplication_threshold 0.85
  @nesting_depth_threshold 5

  import Ragex.MCP.Handlers.Tools, only: [format_reason: 1]

  @doc """
  Returns list of all available pattern types.
  """
  def all_patterns do
    [
      :extract_function,
      :inline_function,
      :split_module,
      :merge_modules,
      :remove_dead_code,
      :reduce_coupling,
      :simplify_complexity,
      :extract_module,
      :introduce_fsm
    ]
  end

  @doc """
  Detects a specific pattern in the analysis data.

  ## Parameters
  - `pattern` - Pattern type to detect
  - `analysis_data` - Analysis data from Suggestions.gather_analysis_data/2
  - `opts` - Additional options

  ## Returns
  - `{:ok, [suggestion]}` - List of raw suggestions (not yet scored)
  - `{:error, reason}` - Error if detection fails
  """
  def detect(pattern, analysis_data, opts \\ [])

  def detect(:extract_function, data, _opts) do
    suggestions =
      []
      |> detect_long_functions(data)
      |> detect_duplicate_code_blocks(data)
      |> Enum.uniq_by(&suggestion_key/1)

    {:ok, suggestions}
  end

  def detect(:inline_function, data, _opts) do
    suggestions = detect_trivial_functions(data)
    {:ok, suggestions}
  end

  def detect(:split_module, data, _opts) do
    suggestions = detect_god_modules(data)
    {:ok, suggestions}
  end

  def detect(:merge_modules, data, _opts) do
    suggestions = detect_similar_modules(data)
    {:ok, suggestions}
  end

  def detect(:remove_dead_code, data, _opts) do
    suggestions = detect_dead_code(data)
    {:ok, suggestions}
  end

  def detect(:reduce_coupling, data, _opts) do
    suggestions =
      []
      |> detect_high_coupling(data)
      |> detect_circular_dependencies(data)

    {:ok, suggestions}
  end

  def detect(:simplify_complexity, data, _opts) do
    suggestions =
      []
      |> detect_complex_functions(data)
      |> detect_deep_nesting(data)

    {:ok, suggestions}
  end

  def detect(:extract_module, data, _opts) do
    suggestions = detect_related_scattered_functions(data)
    {:ok, suggestions}
  end

  def detect(:introduce_fsm, data, _opts) do
    suggestions = detect_imperative_status_handling(data)
    {:ok, suggestions}
  end

  def detect(_unknown, _data, _opts) do
    {:error, :unknown_pattern}
  end

  # Pattern 1: Extract Function - Long functions
  defp detect_long_functions(acc, data) do
    quality = data.quality

    case quality do
      %{functions: functions} when is_list(functions) ->
        long_functions =
          functions
          |> Enum.filter(fn func ->
            complexity = get_in(func, [:metrics, :complexity, :cyclomatic]) || 0
            loc = get_in(func, [:metrics, :loc]) || 0

            (complexity > @complexity_threshold_high and loc > @loc_threshold_medium) or
              loc > @loc_threshold_long
          end)
          |> Enum.map(&build_extract_function_suggestion(&1, :long_function, data))

        acc ++ long_functions

      _ ->
        acc
    end
  end

  # Pattern 1: Extract Function - Duplicate code blocks
  defp detect_duplicate_code_blocks(acc, data) do
    duplication = data.duplication

    case duplication do
      %{clones: [_ | _] = clones} ->
        duplicate_suggestions =
          clones
          |> Enum.filter(fn clone ->
            clone.similarity >= @duplication_threshold and
              clone.clone_type in [:type_i, :type_ii]
          end)
          |> Enum.map(&build_duplication_suggestion/1)

        acc ++ duplicate_suggestions

      _ ->
        acc
    end
  end

  defp build_extract_function_suggestion(func, reason_type, data) do
    complexity = get_in(func, [:metrics, :complexity, :cyclomatic]) || 0
    loc = get_in(func, [:metrics, :loc]) || 0
    module = func[:module]
    name = func[:name]
    arity = func[:arity] || 0

    reason =
      case reason_type do
        :long_function ->
          "Function is too long (#{loc} lines) with high complexity (#{complexity})"

        :duplicate ->
          "Function contains duplicate code that should be extracted"
      end

    %{
      id: generate_id(),
      pattern: :extract_function,
      target: %{
        type: :function,
        module: module,
        function: name,
        arity: arity,
        file: func[:file]
      },
      reason: reason,
      metrics: %{
        complexity: complexity,
        loc: loc,
        cognitive_complexity: get_in(func, [:metrics, :complexity, :cognitive])
      },
      confidence: calculate_extract_confidence(complexity, loc),
      benefit_score: calculate_benefit(complexity, loc),
      effort_score: calculate_extract_effort(loc),
      impact: estimate_impact(data, {:function, module, name, arity}),
      examples: []
    }
  end

  defp build_duplication_suggestion(clone) do
    %{
      id: generate_id(),
      pattern: :extract_function,
      target: %{
        type: :files,
        file1: clone.file1,
        file2: clone.file2
      },
      reason:
        "Duplicate code detected (#{clone.clone_type}, similarity: #{Float.round(clone.similarity, 2)})",
      metrics: %{
        similarity: clone.similarity,
        clone_type: clone.clone_type
      },
      confidence: clone.similarity,
      benefit_score: clone.similarity * 0.9,
      effort_score: 0.5,
      impact: %{affected_files: 2, risk: :low},
      examples: []
    }
  end

  # Pattern 2: Inline Function - Trivial wrappers
  defp detect_trivial_functions(data) do
    quality = data.quality

    case quality do
      %{functions: functions} when is_list(functions) ->
        functions
        |> Enum.filter(&trivial_function?/1)
        |> Enum.map(&build_inline_suggestion/1)

      _ ->
        []
    end
  end

  defp trivial_function?(func) do
    loc = get_in(func, [:metrics, :loc]) || 0
    complexity = get_in(func, [:metrics, :complexity, :cyclomatic]) || 0
    # Single caller check would require graph traversal
    loc <= 3 and complexity <= 1
  end

  defp build_inline_suggestion(func) do
    module = func[:module]
    name = func[:name]
    arity = func[:arity] || 0

    %{
      id: generate_id(),
      pattern: :inline_function,
      target: %{
        type: :function,
        module: module,
        function: name,
        arity: arity
      },
      reason: "Trivial function that could be inlined",
      metrics: %{
        loc: get_in(func, [:metrics, :loc]),
        complexity: get_in(func, [:metrics, :complexity, :cyclomatic])
      },
      confidence: 0.7,
      benefit_score: 0.3,
      effort_score: 0.2,
      impact: %{affected_files: 1, risk: :low},
      examples: []
    }
  end

  # Pattern 3: Split Module - God modules
  defp detect_god_modules(data) do
    _quality = data.quality
    graph_info = data.graph_info
    dependencies = data.dependencies

    function_count = get_in(graph_info, [:function_count]) || 0
    instability = get_in(dependencies, [:instability]) || 0

    cond do
      function_count > @module_function_count_threshold ->
        [build_split_module_suggestion(data, :too_many_functions)]

      function_count > 20 and instability > @coupling_threshold ->
        [build_split_module_suggestion(data, :high_instability)]

      true ->
        []
    end
  end

  defp build_split_module_suggestion(data, reason_type) do
    target = data.target
    function_count = get_in(data.graph_info, [:function_count]) || 0
    instability = get_in(data.dependencies, [:instability]) || 0

    reason =
      case reason_type do
        :too_many_functions ->
          "Module has too many functions (#{function_count}), low cohesion likely"

        :high_instability ->
          "Module has high instability (#{Float.round(instability, 2)}) and many functions"
      end

    %{
      id: generate_id(),
      pattern: :split_module,
      target: %{
        type: :module,
        module: elem(target, 1)
      },
      reason: reason,
      metrics: %{
        function_count: function_count,
        instability: instability
      },
      confidence: calculate_split_confidence(function_count, instability),
      benefit_score: min(function_count / 50.0, 1.0),
      effort_score: 0.8,
      impact: %{affected_files: 1, risk: :high},
      examples: []
    }
  end

  # Pattern 4: Merge Modules - Similar small modules
  defp detect_similar_modules(_data) do
    # Would require cross-module analysis
    # Placeholder for future implementation
    []
  end

  # Pattern 5: Remove Dead Code
  defp detect_dead_code(data) do
    dead_code = data.dead_code

    case dead_code do
      %{dead_functions: [_ | _] = functions} ->
        functions
        |> Enum.filter(fn dead -> dead.confidence >= 0.7 end)
        |> Enum.map(&build_dead_code_suggestion/1)

      _ ->
        []
    end
  end

  defp build_dead_code_suggestion(dead) do
    {:function, module, name, arity} = dead.function

    %{
      id: generate_id(),
      pattern: :remove_dead_code,
      target: %{
        type: :function,
        module: module,
        function: name,
        arity: arity
      },
      reason: format_reason(dead.reason),
      metrics: %{
        visibility: dead.visibility,
        confidence: dead.confidence
      },
      confidence: dead.confidence,
      benefit_score: 0.6,
      effort_score: 0.1,
      impact: %{affected_files: 1, risk: :low},
      examples: []
    }
  end

  # Pattern 6: Reduce Coupling - High coupling
  defp detect_high_coupling(acc, data) do
    dependencies = data.dependencies

    case dependencies do
      %{efferent: ce, instability: instability}
      when ce > 10 and instability > @coupling_threshold ->
        suggestion = build_coupling_suggestion(data, :high_efferent)
        [suggestion | acc]

      _ ->
        acc
    end
  end

  # Pattern 6: Reduce Coupling - Circular dependencies
  defp detect_circular_dependencies(acc, data) do
    dependencies = data.dependencies

    case dependencies do
      %{circular: [_ | _] = _circular} ->
        suggestion = build_coupling_suggestion(data, :circular)
        [suggestion | acc]

      _ ->
        acc
    end
  end

  defp build_coupling_suggestion(data, reason_type) do
    target = data.target
    dependencies = data.dependencies

    reason =
      case reason_type do
        :high_efferent ->
          ce = dependencies.efferent
          "High efferent coupling (#{ce}), module depends on too many others"

        :circular ->
          "Circular dependencies detected"
      end

    %{
      id: generate_id(),
      pattern: :reduce_coupling,
      target: %{
        type: :module,
        module: elem(target, 1)
      },
      reason: reason,
      metrics: %{
        afferent: dependencies[:afferent],
        efferent: dependencies[:efferent],
        instability: dependencies[:instability]
      },
      confidence: 0.75,
      benefit_score: 0.7,
      effort_score: 0.7,
      impact: %{affected_files: dependencies[:efferent] || 1, risk: :medium},
      examples: []
    }
  end

  # Pattern 7: Simplify Complexity - Complex functions
  defp detect_complex_functions(acc, data) do
    quality = data.quality

    case quality do
      %{functions: functions} when is_list(functions) ->
        complex =
          functions
          |> Enum.filter(fn func ->
            complexity = get_in(func, [:metrics, :complexity, :cyclomatic]) || 0
            complexity >= @complexity_threshold_high
          end)
          |> Enum.map(&build_complexity_suggestion(&1, :high_complexity))

        acc ++ complex

      _ ->
        acc
    end
  end

  # Pattern 7: Simplify Complexity - Deep nesting
  defp detect_deep_nesting(acc, data) do
    quality = data.quality

    case quality do
      %{functions: functions} when is_list(functions) ->
        nested =
          functions
          |> Enum.filter(fn func ->
            nesting = get_in(func, [:metrics, :complexity, :nesting_depth]) || 0
            nesting >= @nesting_depth_threshold
          end)
          |> Enum.map(&build_complexity_suggestion(&1, :deep_nesting))

        acc ++ nested

      _ ->
        acc
    end
  end

  defp build_complexity_suggestion(func, reason_type) do
    module = func[:module]
    name = func[:name]
    arity = func[:arity] || 0
    complexity = get_in(func, [:metrics, :complexity, :cyclomatic]) || 0
    nesting = get_in(func, [:metrics, :complexity, :nesting_depth]) || 0

    reason =
      case reason_type do
        :high_complexity ->
          "High cyclomatic complexity (#{complexity})"

        :deep_nesting ->
          "Deep nesting depth (#{nesting} levels)"
      end

    %{
      id: generate_id(),
      pattern: :simplify_complexity,
      target: %{
        type: :function,
        module: module,
        function: name,
        arity: arity
      },
      reason: reason,
      metrics: %{
        cyclomatic_complexity: complexity,
        nesting_depth: nesting,
        cognitive_complexity: get_in(func, [:metrics, :complexity, :cognitive])
      },
      confidence: min(complexity / 20.0, 1.0),
      benefit_score: min(complexity / 15.0, 1.0),
      effort_score: 0.6,
      impact: %{affected_files: 1, risk: :medium},
      examples: []
    }
  end

  # Pattern 8: Extract Module - Related scattered functions
  defp detect_related_scattered_functions(_data) do
    # Would require semantic analysis across modules
    # Placeholder for future implementation
    []
  end

  # Pattern 9: Introduce FSM - Imperative status management
  defp detect_imperative_status_handling(data) do
    # Collect imperative_status_handling issues from business logic analysis
    bl_issues = get_business_logic_issues(data, :imperative_status_handling)

    if bl_issues == [] do
      []
    else
      # Group issues by file to build per-module suggestions
      bl_issues
      |> Enum.group_by(& &1[:file])
      |> Enum.flat_map(fn {file, issues} ->
        build_fsm_suggestions(file, issues, data)
      end)
    end
  end

  defp get_business_logic_issues(data, analyzer_name) do
    case data do
      %{quality: %{business_logic: %{issues: issues}}} when is_list(issues) ->
        Enum.filter(issues, fn issue ->
          issue[:analyzer] == Metastatic.Analysis.BusinessLogic.ImperativeStatusHandling or
            issue[:analyzer] == analyzer_name
        end)

      _ ->
        []
    end
  end

  defp build_fsm_suggestions(file, issues, _data) do
    # Collect all detected states from issue metadata
    all_states =
      issues
      |> Enum.flat_map(fn issue ->
        context = issue[:context] || %{}

        cond do
          is_list(context[:detected_states]) -> context[:detected_states]
          context[:assigned_state] -> [context[:assigned_state]]
          true -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    # Collect transition-verb functions
    verb_functions =
      issues
      |> Enum.filter(fn issue ->
        context = issue[:context] || %{}
        context[:tier] == :transition_verb
      end)
      |> Enum.map(fn issue ->
        context = issue[:context] || %{}
        context[:function_name] || context[:matched_verb]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Only suggest if enough evidence
    if length(all_states) >= 3 or (length(all_states) >= 2 and length(verb_functions) >= 2) do
      mermaid = generate_mermaid_diagram(all_states, verb_functions)
      skeleton = generate_finitomata_skeleton(all_states, verb_functions)

      tiers_present =
        issues
        |> Enum.map(&get_in(&1, [:context, :tier]))
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1)

      confidence = calculate_fsm_confidence(all_states, verb_functions, tiers_present)

      [
        %{
          id: generate_id(),
          pattern: :introduce_fsm,
          target: %{
            type: :file,
            file: file
          },
          reason:
            "Module manages #{length(all_states)} status values (#{Enum.map_join(all_states, ", ", &inspect/1)}) " <>
              "imperatively -- replace with FSM for explicit transitions and validation",
          metrics: %{
            state_count: length(all_states),
            detected_states: all_states,
            transition_functions: verb_functions,
            evidence_tiers: tiers_present
          },
          confidence: confidence,
          benefit_score: 0.85,
          effort_score: 0.6,
          impact: %{affected_files: 1, risk: :medium},
          examples: [],
          fsm_diagram: mermaid,
          fsm_skeleton: skeleton
        }
      ]
    else
      []
    end
  end

  defp generate_mermaid_diagram(states, verb_functions) do
    lines = ["stateDiagram-v2"]

    # Initial transition
    first_state = List.first(states)
    lines = lines ++ ["    [*] --> #{format_state_name(first_state)}"]

    # Infer transitions from verb functions and state ordering
    transition_lines =
      case verb_functions do
        [_ | _] ->
          # Pair states with verbs where possible
          states
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.zip(Stream.concat(verb_functions, Stream.repeatedly(fn -> "transition" end)))
          |> Enum.map(fn {[from, to], verb} ->
            "    #{format_state_name(from)} --> #{format_state_name(to)} : #{verb}"
          end)

        [] ->
          # Just show state progression
          states
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [from, to] ->
            "    #{format_state_name(from)} --> #{format_state_name(to)}"
          end)
      end

    # Final transition
    last_state = List.last(states)
    final_line = "    #{format_state_name(last_state)} --> [*]"

    Enum.join(lines ++ transition_lines ++ [final_line], "\n")
  end

  defp generate_finitomata_skeleton(states, verb_functions) do
    # Build the FSM definition string
    transitions =
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.zip(Stream.concat(verb_functions, Stream.repeatedly(fn -> "transition" end)))
      |> Enum.map_join("\n    ", fn {[from, to], verb} ->
        "#{format_state_name(from)} --> |#{verb}| #{format_state_name(to)}"
      end)

    # Build on_transition callback stubs
    callbacks =
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.zip(Stream.concat(verb_functions, Stream.repeatedly(fn -> "transition" end)))
      |> Enum.map_join("\n\n  ", fn {[from, to], verb} ->
        "def on_transition(:#{format_state_name(from)}, :#{verb}, _event_payload, state_payload),\n" <>
          "    do: {:ok, :#{format_state_name(to)}, state_payload}"
      end)

    """
    defmodule MyApp.EntityFSM do
      @fsm \"\"\"\n    #{transitions}
      \"\"\"

      use Finitomata, fsm: @fsm, syntax: :flowchart

      @impl Finitomata
      #{callbacks}
    end
    """
    |> String.trim()
  end

  defp format_state_name(state) when is_atom(state), do: Atom.to_string(state)
  defp format_state_name(state) when is_binary(state), do: state
  defp format_state_name(state), do: inspect(state)

  defp calculate_fsm_confidence(states, verb_functions, tiers) do
    state_factor = min(length(states) / 5.0, 1.0) * 0.4
    verb_factor = min(length(verb_functions) / 3.0, 1.0) * 0.3
    tier_factor = min(length(tiers) / 3.0, 1.0) * 0.3
    Float.round(state_factor + verb_factor + tier_factor, 2)
  end

  # Helper functions

  defp suggestion_key(suggestion) do
    {suggestion.pattern, suggestion.target}
  end

  defp calculate_extract_confidence(complexity, loc) do
    complexity_factor = min(complexity / 20.0, 1.0)
    loc_factor = min(loc / 80.0, 1.0)
    Float.round((complexity_factor + loc_factor) / 2.0, 2)
  end

  defp calculate_split_confidence(function_count, instability) do
    count_factor = min(function_count / 50.0, 1.0)
    instability_factor = instability
    Float.round((count_factor + instability_factor) / 2.0, 2)
  end

  defp calculate_benefit(complexity, loc) do
    complexity_benefit = min(complexity / 15.0, 1.0) * 0.6
    loc_benefit = min(loc / 60.0, 1.0) * 0.4
    Float.round(complexity_benefit + loc_benefit, 2)
  end

  defp calculate_extract_effort(loc) do
    # More lines = more effort to extract
    base_effort = min(loc / 100.0, 1.0) * 0.7
    Float.round(base_effort + 0.3, 2)
  end

  defp estimate_impact(_data, _target) do
    # Simplified impact estimation
    # In practice, would call Impact.analyze_change/2
    %{affected_files: 1, risk: :low}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
