# Ragex Code Analysis Guide

Comprehensive guide to Ragex's code analysis capabilities powered by Metastatic and semantic embeddings.

## Table of Contents

1. [Overview](#overview)
2. [Analysis Approaches](#analysis-approaches)
3. [Code Duplication Detection](#code-duplication-detection)
4. [Dead Code Detection](#dead-code-detection)
5. [Dependency Analysis](#dependency-analysis)
6. [Impact Analysis](#impact-analysis)
7. [MCP Tools Reference](#mcp-tools-reference)
8. [Best Practices](#best-practices)
9. [Troubleshooting](#troubleshooting)

## Overview

Ragex provides advanced code analysis capabilities through two complementary approaches:

1. **AST-Based Analysis** - Precise structural analysis via Metastatic
2. **Embedding-Based Analysis** - Semantic similarity via ML embeddings

All analysis features are accessible via MCP tools and can be integrated into your development workflow.

### Supported Languages

- Elixir (.ex, .exs)
- Erlang (.erl, .hrl)
- LFE (.lfe)
- Python (.py)
- JavaScript/TypeScript (.js, .ts)
- Ruby (.rb)
- Haskell (.hs, .lhs)

## Analysis Approaches

### AST-Based Analysis (Metastatic)

**Advantages:**
- Precise structural matching
- Language-aware analysis
- Detects subtle code patterns
- No training required

**Use Cases:**
- Exact and near-exact code duplication
- Dead code detection (unreachable code)
- Structural similarity analysis

### Embedding-Based Analysis

**Advantages:**
- Semantic understanding
- Cross-language similarity
- Finds conceptually similar code
- Works with comments and documentation

**Use Cases:**
- Finding semantically similar functions
- Code smell detection
- Refactoring opportunities
- Cross-project similarity

## Code Duplication Detection

Ragex detects four types of code clones using Metastatic's AST comparison:

### Clone Types

#### Type I: Exact Clones
Identical code with only whitespace/comment differences.

```elixir
# File 1
defmodule A do
  def calculate(x, y) do
    x + y * 2
  end
end

# File 2 (Type I clone)
defmodule A do
  def calculate(x, y) do
    x + y * 2
  end
end
```

#### Type II: Renamed Clones
Same structure with different identifiers.

```elixir
# File 1
defmodule A do
  def process(data, options) do
    Map.put(data, :result, options.value)
  end
end

# File 2 (Type II clone)
defmodule A do
  def process(input, config) do
    Map.put(input, :result, config.value)
  end
end
```

#### Type III: Near-Miss Clones
Similar structure with minor modifications.

```elixir
# File 1
defmodule A do
  def process(x) do
    result = x * 10
    result + 100
  end
end

# File 2 (Type III clone)
defmodule A do
  def process(x) do
    result = x * 10
    result + 200  # Different constant
  end
end
```

#### Type IV: Semantic Clones
Different syntax, same behavior.

```elixir
# File 1
def sum_list(items) do
  Enum.reduce(items, 0, &+/2)
end

# File 2 (Type IV clone)
def sum_list(items) do
  items |> Enum.sum()
end
```

### API Usage

#### Detect Duplicates Between Two Files

```elixir
alias Ragex.Analysis.Duplication

# Basic usage
{:ok, result} = Duplication.detect_between_files("lib/a.ex", "lib/b.ex")

if result.duplicate? do
  IO.puts("Found #{result.clone_type} clone")
  IO.puts("Similarity: #{result.similarity_score}")
end

# With options
{:ok, result} = Duplication.detect_between_files(
  "lib/a.ex", 
  "lib/b.ex",
  threshold: 0.9  # Stricter matching
)
```

#### Detect Duplicates Across Multiple Files

```elixir
files = ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
{:ok, clones} = Duplication.detect_in_files(files)

Enum.each(clones, fn clone ->
  IO.puts("#{clone.file1} <-> #{clone.file2}")
  IO.puts("  Type: #{clone.clone_type}")
  IO.puts("  Similarity: #{clone.similarity}")
end)
```

#### Scan Directory for Duplicates

```elixir
# Recursive scan with defaults
{:ok, clones} = Duplication.detect_in_directory("lib/")

# Custom options
{:ok, clones} = Duplication.detect_in_directory("lib/", 
  recursive: true,
  threshold: 0.8,
  exclude_patterns: ["_build", "deps", ".git", "test"]
)

IO.puts("Found #{length(clones)} duplicate pairs")
```

#### Embedding-Based Similarity

```elixir
# Find similar functions using embeddings
{:ok, similar} = Duplication.find_similar_functions(
  threshold: 0.95,  # High similarity
  limit: 20,
  node_type: :function
)

Enum.each(similar, fn pair ->
  IO.puts("#{inspect(pair.function1)} ~ #{inspect(pair.function2)}")
  IO.puts("  Similarity: #{pair.similarity}")
  IO.puts("  Method: #{pair.method}")  # :embedding
end)
```

#### Generate Comprehensive Report

```elixir
{:ok, report} = Duplication.generate_report("lib/", 
  include_embeddings: true,
  threshold: 0.8
)

IO.puts(report.summary)
IO.puts("AST clones: #{report.ast_clones.total}")
IO.puts("Embedding similar: #{report.embedding_similar.total}")

# Access detailed data
report.ast_clones.by_type  # %{type_i: 5, type_ii: 3, ...}
report.ast_clones.pairs    # List of clone pairs
report.embedding_similar.pairs  # List of similar pairs
```

### MCP Tools

#### `find_duplicates`

Detect duplicates using AST-based analysis.

```json
{
  "name": "find_duplicates",
  "arguments": {
    "mode": "directory",
    "path": "lib/",
    "threshold": 0.8,
    "format": "detailed"
  }
}
```

**Modes:**
- `"directory"` - Scan entire directory
- `"files"` - Compare specific files (provide `file1` and `file2`)

**Formats:**
- `"summary"` - Brief overview
- `"detailed"` - Full clone information
- `"json"` - Machine-readable JSON

#### `find_similar_code`

Find semantically similar code using embeddings.

```json
{
  "name": "find_similar_code",
  "arguments": {
    "threshold": 0.95,
    "limit": 20,
    "format": "summary"
  }
}
```

## Dead Code Detection

Ragex provides two types of dead code detection:

### 1. Interprocedural (Graph-Based)

Detects unused functions by analyzing the call graph.

```elixir
alias Ragex.Analysis.DeadCode

# Find unused public functions
{:ok, unused_exports} = DeadCode.find_unused_exports()
# Returns: [{:module, ModuleName, :function_name, arity}, ...]

# Find unused private functions
{:ok, unused_private} = DeadCode.find_unused_private()

# Find unused modules
{:ok, unused_modules} = DeadCode.find_unused_modules()

# Generate removal suggestions
{:ok, suggestions} = DeadCode.removal_suggestions(confidence_threshold: 0.8)
```

### 2. Intraprocedural (AST-Based via Metastatic)

Detects unreachable code patterns within functions.

```elixir
# Analyze single file
{:ok, patterns} = DeadCode.analyze_file("lib/my_module.ex")

Enum.each(patterns, fn pattern ->
  IO.puts("#{pattern.type}: Line #{pattern.line}")
  IO.puts("  #{pattern.description}")
end)

# Analyze directory
{:ok, results} = DeadCode.analyze_files("lib/")
# Returns: Map of file paths to dead code patterns
```

**Detected Patterns:**
- Unreachable code after `return`
- Constant conditions (always true/false)
- Unused variables
- Dead branches

### MCP Tools

#### `find_dead_code`

Graph-based unused function detection.

```json
{
  "name": "find_dead_code",
  "arguments": {
    "confidence_threshold": 0.8,
    "include_private": true,
    "format": "detailed"
  }
}
```

#### `analyze_dead_code_patterns`

AST-based unreachable code detection.

```json
{
  "name": "analyze_dead_code_patterns",
  "arguments": {
    "path": "lib/my_module.ex",
    "format": "json"
  }
}
```

## Dependency Analysis

Analyze module dependencies and coupling.

### Finding Circular Dependencies

```elixir
alias Ragex.Analysis.DependencyGraph

# Find all circular dependencies
{:ok, cycles} = DependencyGraph.find_cycles()

Enum.each(cycles, fn cycle ->
  IO.puts("Cycle: #{inspect(cycle)}")
end)
```

### Coupling Metrics

```elixir
# Calculate coupling for a module
metrics = DependencyGraph.coupling_metrics(MyModule)

IO.puts("Afferent coupling: #{metrics.afferent}")  # Incoming deps
IO.puts("Efferent coupling: #{metrics.efferent}")  # Outgoing deps
IO.puts("Instability: #{metrics.instability}")     # 0.0 to 1.0
```

**Instability** = efferent / (afferent + efferent)
- 0.0 = Stable (many dependents, few dependencies)
- 1.0 = Unstable (few dependents, many dependencies)

### Finding God Modules

```elixir
# Modules with high coupling
{:ok, god_modules} = DependencyGraph.find_god_modules(threshold: 10)
```

### MCP Tools

#### `analyze_dependencies`

```json
{
  "name": "analyze_dependencies",
  "arguments": {
    "module": "MyModule",
    "include_transitive": true
  }
}
```

#### `find_circular_dependencies`

```json
{
  "name": "find_circular_dependencies",
  "arguments": {
    "min_cycle_length": 2
  }
}
```

#### `coupling_report`

```json
{
  "name": "coupling_report",
  "arguments": {
    "format": "json",
    "sort_by": "instability"
  }
}
```

## Impact Analysis

Predict the impact of code changes before making them using graph traversal and metrics.

### Overview

Impact Analysis answers critical questions:
- Which code will be affected by this change?
- Which tests need to run?
- How risky is this refactoring?
- How much effort will this take?

**Key Features:**
- Graph-based call chain analysis
- Risk scoring (importance + coupling + complexity)
- Effort estimation for refactoring operations
- Test discovery

### Analyzing Change Impact

```elixir
alias Ragex.Analysis.Impact

# Analyze impact of changing a function
{:ok, analysis} = Impact.analyze_change({:function, MyModule, :process, 2})

IO.puts("Direct callers: #{length(analysis.direct_callers)}")
IO.puts("Total affected: #{analysis.affected_count}")
IO.puts("Risk score: #{analysis.risk_score}")
IO.puts("Importance: #{analysis.importance}")

# Show recommendations
Enum.each(analysis.recommendations, &IO.puts/1)
```

**Parameters:**
- `depth` - Maximum traversal depth (default: 5)
- `include_tests` - Include test files in analysis (default: true)
- `exclude_modules` - Modules to exclude from traversal

**Returns:**
- `target` - The node being analyzed
- `direct_callers` - Functions that directly call this
- `all_affected` - All reachable callers (transitive)
- `affected_count` - Total number of affected nodes
- `risk_score` - Overall risk (0.0 to 1.0)
- `importance` - PageRank-based importance
- `recommendations` - Actionable advice

### Finding Affected Tests

```elixir
# Find tests that will be affected by changing this function
{:ok, tests} = Impact.find_affected_tests({:function, MyModule, :process, 2})

IO.puts("#{length(tests)} tests affected")

Enum.each(tests, fn {:function, module, name, arity} ->
  IO.puts("  - #{module}.#{name}/#{arity}")
end)
```

**Custom Test Patterns:**
```elixir
# Support non-standard test naming (e.g., specs)
{:ok, tests} = Impact.find_affected_tests(
  {:function, MyModule, :process, 2},
  test_patterns: ["Spec", "Test", "_test"]
)
```

### Estimating Refactoring Effort

```elixir
# Estimate effort for rename operation
{:ok, estimate} = Impact.estimate_effort(
  :rename_function,
  {:function, MyModule, :old_name, 2}
)

IO.puts("Operation: #{estimate.operation}")
IO.puts("Changes needed: #{estimate.estimated_changes} locations")
IO.puts("Complexity: #{estimate.complexity}")
IO.puts("Time estimate: #{estimate.estimated_time}")

# Review risks
IO.puts("\nRisks:")
Enum.each(estimate.risks, fn risk ->
  IO.puts("  - #{risk}")
end)

# Review recommendations
IO.puts("\nRecommendations:")
Enum.each(estimate.recommendations, fn rec ->
  IO.puts("  - #{rec}")
end)
```

**Supported Operations:**
- `:rename_function` - Rename a function
- `:rename_module` - Rename a module
- `:extract_function` - Extract code into new function
- `:inline_function` - Inline a function
- `:move_function` - Move function to another module
- `:change_signature` - Change function signature

**Complexity Levels:**
- `:low` - < 5 affected locations (< 30 min)
- `:medium` - 5-20 locations (30 min - 2 hours)
- `:high` - 20-50 locations (2-4 hours)
- `:very_high` - 50+ locations (1+ day)

### Risk Assessment

```elixir
# Calculate risk score for a change
{:ok, risk} = Impact.risk_score({:function, MyModule, :critical_fn, 1})

IO.puts("Target: #{inspect(risk.target)}")
IO.puts("Overall risk: #{risk.overall} (#{risk.level})")
IO.puts("\nComponents:")
IO.puts("  Importance: #{risk.importance}  # PageRank")
IO.puts("  Coupling: #{risk.coupling}      # Edges")
IO.puts("  Complexity: #{risk.complexity}  # Code metrics")
```

**Risk Levels:**
- `:low` - Overall < 0.3 (safe to change)
- `:medium` - 0.3 ≤ Overall < 0.6 (needs review)
- `:high` - 0.6 ≤ Overall < 0.8 (risky, comprehensive testing)
- `:critical` - Overall ≥ 0.8 (very risky, plan carefully)

**Risk Components:**
1. **Importance** - Based on PageRank (how central in the call graph)
2. **Coupling** - Number of incoming/outgoing edges (normalized)
3. **Complexity** - Code complexity metrics (if available)

### MCP Tools

#### `analyze_impact`

Analyze the impact of changing a function or module.

```json
{
  "name": "analyze_impact",
  "arguments": {
    "target": "MyModule.process/2",
    "depth": 5,
    "include_tests": true,
    "format": "detailed"
  }
}
```

**Target Formats:**
- `"Module.function/arity"` - Specific function
- `"Module"` - Entire module

#### `estimate_refactoring_effort`

Estimate effort for a refactoring operation.

```json
{
  "name": "estimate_refactoring_effort",
  "arguments": {
    "operation": "rename_function",
    "target": "MyModule.old_name/2",
    "format": "summary"
  }
}
```

**Operations:** `rename_function`, `rename_module`, `extract_function`, `inline_function`, `move_function`, `change_signature`

#### `risk_assessment`

Calculate risk score for a change.

```json
{
  "name": "risk_assessment",
  "arguments": {
    "target": "MyModule.critical/1",
    "format": "detailed"
  }
}
```

### Workflow Example

**Before Refactoring:**

```elixir
# Step 1: Analyze impact
{:ok, impact} = Impact.analyze_change({:function, MyModule, :old_name, 2})

if impact.affected_count > 20 do
  IO.puts("Warning: Large impact (#{impact.affected_count} locations)")
end

# Step 2: Find affected tests
{:ok, tests} = Impact.find_affected_tests({:function, MyModule, :old_name, 2})
IO.puts("Tests to run: #{length(tests)}")

# Step 3: Estimate effort
{:ok, estimate} = Impact.estimate_effort(
  :rename_function, 
  {:function, MyModule, :old_name, 2}
)
IO.puts("Estimated time: #{estimate.estimated_time}")

# Step 4: Assess risk
{:ok, risk} = Impact.risk_score({:function, MyModule, :old_name, 2})

case risk.level do
  :low -> IO.puts("✓ Safe to proceed")
  :medium -> IO.puts("⚠ Review carefully")
  :high -> IO.puts("⚠ High risk - thorough testing required")
  :critical -> IO.puts("❌ Critical risk - consider alternative approach")
end

# Step 5: Proceed with refactoring if acceptable
if risk.level in [:low, :medium] do
  # Run refactoring
  # Run affected tests
  # Commit changes
end
```

### Best Practices

1. **Always analyze before refactoring** - Know the scope of changes
2. **Check risk levels** - Don't proceed with critical-risk changes without planning
3. **Run affected tests** - Use test discovery to optimize CI time
4. **Review transitive callers** - Indirect impacts can be significant
5. **Consider alternatives** - High-risk operations may have safer approaches
6. **Document high-impact changes** - Leave notes for future maintainers
7. **Use depth wisely** - Deep traversal (depth > 10) can be expensive
8. **Exclude test files for production impact** - Use `include_tests: false`

### Limitations

**Current limitations:**
- Dynamic function calls (apply, send) not fully tracked
- Macros may not be accurately analyzed
- Cross-module dependencies require full analysis
- Complexity metrics require quality analysis to be run first

**Workarounds:**
- Run comprehensive analysis before impact analysis
- Manually review dynamic call sites
- Use conservative estimates for macro-heavy code
- Lower confidence scores indicate potential dynamic usage

## MCP Tools Reference

### Summary of All Analysis Tools

| Tool | Purpose | Analysis Type |
|------|---------|---------------|
| `find_duplicates` | Code duplication detection | AST (Metastatic) |
| `find_similar_code` | Semantic similarity | Embedding |
| `find_dead_code` | Unused functions | Graph |
| `analyze_dead_code_patterns` | Unreachable code | AST (Metastatic) |
| `analyze_dependencies` | Module dependencies | Graph |
| `find_circular_dependencies` | Circular deps | Graph |
| `coupling_report` | Coupling metrics | Graph |
| `analyze_impact` | Change impact analysis | Graph |
| `estimate_refactoring_effort` | Effort estimation | Graph + Metrics |
| `risk_assessment` | Risk scoring | Graph + PageRank |

### Common Parameters

**Formats:**
- `"summary"` - Brief, human-readable
- `"detailed"` - Complete information
- `"json"` - Machine-readable JSON

**Thresholds:**
- Duplication: 0.8-0.95 (higher = stricter)
- Similarity: 0.9-0.99 (higher = more similar)
- Confidence: 0.7-0.9 (higher = more certain)

## Best Practices

### Duplication Detection

1. **Start with high thresholds** (0.9+) to find obvious duplicates
2. **Lower gradually** to find near-misses
3. **Review Type II/III clones carefully** - they may be intentional
4. **Use embedding-based search** for conceptual similarity
5. **Exclude build artifacts** - always exclude `_build`, `deps`, etc.

### Dead Code Detection

1. **Check confidence scores** - low confidence may indicate dynamic calls
2. **Review entry points** - callbacks, GenServer handlers, etc. may not show up in call graph
3. **Combine both approaches** - graph-based for unused functions, AST-based for unreachable code
4. **Run regularly** - integrate into CI/CD pipeline
5. **Keep whitelist** of intentionally unused functions (e.g., API compatibility)

### Dependency Analysis

1. **Monitor instability** - high instability modules are risky to change
2. **Break circular dependencies** - they indicate poor separation of concerns
3. **Watch for God modules** - high coupling suggests need for refactoring
4. **Track trends over time** - coupling should decrease as code improves

### Performance Tips

1. **Use incremental analysis** - only analyze changed files
2. **Exclude test directories** for production analysis
3. **Limit depth** for transitive dependency analysis
4. **Cache results** - Ragex automatically caches embeddings
5. **Run in parallel** - analysis operations are concurrent-safe

## Troubleshooting

### No Duplicates Found (Expected Some)

**Possible causes:**
- Threshold too high - try lowering to 0.7-0.8
- Files not in supported languages - check file extensions
- Structural differences too large - use embedding-based similarity

**Solutions:**
```elixir
# Try lower threshold
{:ok, clones} = Duplication.detect_in_directory("lib/", threshold: 0.7)

# Or use embedding-based similarity
{:ok, similar} = Duplication.find_similar_functions(threshold: 0.85)
```

### Too Many False Positives

**Possible causes:**
- Threshold too low
- Structural patterns common in the language (e.g., GenServer boilerplate)
- Short functions with similar structure

**Solutions:**
```elixir
# Increase threshold
{:ok, clones} = Duplication.detect_in_directory("lib/", threshold: 0.95)

# Filter by minimum size
clones
|> Enum.filter(fn clone -> 
  clone.details.locations 
  |> Enum.any?(fn loc -> loc.lines > 5 end)
end)
```

### Dead Code False Positives

**Possible causes:**
- Dynamic function calls (`apply/3`, `__MODULE__`)
- Reflection usage
- Entry points not in call graph (callbacks, tests)

**Solutions:**
1. Check confidence scores - low confidence = likely dynamic
2. Maintain whitelist of known entry points
3. Review before deletion

### Parse Errors

**Possible causes:**
- Invalid syntax in source files
- Unsupported language features
- Missing language parser

**Solutions:**
```elixir
# Check logs for specific parse errors
# Ragex logs warnings for unparseable files

# Exclude problematic files
{:ok, clones} = Duplication.detect_in_directory("lib/", 
  exclude_patterns: ["problem_file.ex"]
)
```

### Performance Issues

**Symptoms:**
- Slow analysis on large codebases
- Memory usage spikes

**Solutions:**
1. Analyze incrementally (changed files only)
2. Exclude large generated files
3. Use streaming for large result sets
4. Increase system resources

```elixir
# Analyze only changed files
changed_files = ["lib/a.ex", "lib/b.ex"]
{:ok, clones} = Duplication.detect_in_files(changed_files)
```

## Integration Examples

### CI/CD Pipeline

```bash
#!/bin/bash
# detect_issues.sh

# Find duplicates
echo "Checking for code duplication..."
mix ragex.analyze.duplicates --threshold 0.9 --format json > duplicates.json

# Find dead code
echo "Checking for dead code..."
mix ragex.analyze.dead_code --confidence 0.8 --format json > dead_code.json

# Check for circular dependencies
echo "Checking for circular dependencies..."
mix ragex.analyze.cycles --format json > cycles.json

# Fail if issues found
if [ -s duplicates.json ] || [ -s dead_code.json ] || [ -s cycles.json ]; then
  echo "Code quality issues detected!"
  exit 1
fi
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Get staged Elixir files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\\.ex$|\\.exs$')

if [ -n "$STAGED_FILES" ]; then
  echo "Checking staged files for duplication..."
  mix ragex.analyze.duplicates --files $STAGED_FILES --threshold 0.95
fi
```

### Interactive Analysis

```elixir
# In IEx
alias Ragex.Analysis.Duplication

# Generate report
{:ok, report} = Duplication.generate_report("lib/")

# Display summary
IO.puts(report.summary)

# Investigate specific clones
report.ast_clones.pairs
|> Enum.filter(&(&1.clone_type == :type_i))
|> Enum.each(fn clone ->
  IO.puts("\n#{clone.file1} <-> #{clone.file2}")
  IO.puts("  #{clone.details.summary}")
end)
```

## Further Reading

- [Metastatic Documentation](https://github.com/oeditus/metastatic)

---

**Version:** Ragex 0.2.0
**Last Updated:** January 2026
**Status:** Production Ready
