# Troubleshooting Guide

This document provides solutions to common issues and explanations for error messages you might encounter when using Ragex.

## Table of Contents
- [Configuration](#configuration)
- [Error Messages](#error-messages)
- [Analysis Issues](#analysis-issues)

## Configuration

### Suppressing Dead Code Analysis

Dead code detection can be noisy, especially in codebases with many callbacks, entry points, or API functions. You can suppress it in your `config/config.exs`:

```elixir
# Disable dead code detection completely
config :ragex, :analysis,
  enable_dead_code_detection: false

# Or adjust the minimum confidence threshold (0.0-1.0)
config :ragex, :analysis,
  enable_dead_code_detection: true,
  dead_code_min_confidence: 0.8  # Only report high-confidence results
```

**Options:**
- `enable_dead_code_detection` (boolean, default: `true`) - Enable or disable dead code detection entirely
- `dead_code_min_confidence` (float 0.0-1.0, default: `0.5`) - Minimum confidence threshold for reporting

When disabled, all dead code analysis functions (`find_unused_exports`, `find_unused_private`, `find_all_unused`, etc.) will return empty results.

### Adjusting Dead Code Confidence

Dead code detection uses confidence scores to distinguish between truly dead code and potential callbacks/entry points:

- **High confidence (>0.8)**: Likely safe to remove - no callers, not a known callback pattern
- **Medium confidence (0.5-0.8)**: Review recommended - no callers but may be an API function
- **Low confidence (<0.5)**: Likely a callback or entry point - verify before removing

You can adjust the threshold to reduce noise:

```elixir
# Via config
config :ragex, :analysis, dead_code_min_confidence: 0.8

# Via API
DeadCode.find_unused_exports(min_confidence: 0.8)
```

## Error Messages

### "Complex pattern not supported"

**Full message:** `Complex pattern not supported`

**What it means:**  
This error appears when Metastatic's Elixir adapter encounters a comprehension (`for`) with a complex pattern in the generator variable. Metastatic currently supports simple variable patterns but not complex destructuring patterns.

**Example that causes this:**
```elixir
# Complex pattern - NOT supported
for {key, value} <- map, do: {value, key}

# Complex pattern - NOT supported  
for %{id: id, name: name} <- users, do: {id, name}
```

**Workaround:**
```elixir
# Use Enum functions instead
map |> Enum.map(fn {key, value} -> {value, key} end)

# Or use a simple variable and destructure in the body
for item <- users do
  %{id: id, name: name} = item
  {id, name}
end
```

**Why this happens:**  
Metastatic converts Elixir AST to a language-agnostic MetaAST representation. Complex patterns in comprehension generators require advanced pattern matching analysis that isn't yet implemented. Simple patterns (single variables) work fine because they map directly to lambda parameters in the MetaAST `:collection_op` node.

**Impact:**  
This error only affects AST-based analysis of files with complex comprehension patterns. The error is non-fatal - the comprehension is preserved as a `:language_specific` node in the MetaAST, but semantic analysis of that specific construct will be limited.

**Related:**
- Source: `/opt/Proyectos/Oeditus/metastatic/lib/metastatic/adapters/elixir/to_meta.ex:808`
- The same limitation may apply to other pattern-matching constructs depending on context

## Analysis Issues

### Dead Code False Positives

**Symptom:** Functions you know are used are being reported as dead code.

**Common causes:**

1. **Callbacks and behaviour implementations** - GenServer, Phoenix LiveView, etc.
   - Solution: These are filtered by default. Check if your callback pattern is in the known list.
   - Functions like `mount/3`, `handle_call/3`, `render/1` are automatically recognized.

2. **Entry points** - `main/0`, `run/1`, CLI commands
   - Solution: Entry point patterns (`~r/^main$/`, `~r/^run$/`, `~r/^start/`) are recognized.
   - If you have custom entry points, use `include_callbacks: true` option.

3. **Dynamically called functions** - `apply/3`, `&Module.function/1`
   - Solution: The knowledge graph tracks static calls only. Mark these functions with `@doc false` and exclude from analysis.

4. **External API functions** - Public functions called from outside your codebase
   - Solution: Increase `min_confidence` threshold to only see high-confidence results.

**Example:**
```elixir
# This will have low confidence (won't be flagged) because it's a known callback
def handle_call(:get_state, _from, state) do
  {:reply, state, state}
end

# This will have high confidence if never called internally
def public_api_function(arg) do
  # ...
end
```

### Missing Function Locations in Reports

**Symptom:** Some functions in dead code reports show `unknown` instead of `file:line`.

**Cause:** The function metadata wasn't stored in the knowledge graph, or the file hasn't been analyzed yet.

**Solution:**
1. Ensure the file has been analyzed: `analyze_directory("lib")`
2. Re-analyze the file if it was modified: `analyze_file("lib/my_module.ex")`
3. For modules, at least the file path will be shown if module metadata is available.

### Intraprocedural Dead Code Missing Line Numbers

**Symptom:** Dead code patterns (unreachable code, constant conditionals) show file path but no line numbers.

**Cause:** Metastatic's MetaAST representation doesn't currently preserve line number metadata from the original AST.

**Impact:** You'll see:
```json
{
  "file": "lib/my_module.ex",
  "type": "unreachable_after_return",
  "note": "Line numbers not available (MetaAST limitation)"
}
```

**Workaround:**
- Open the file and search for the pattern type (e.g., code after `return`)
- Use your editor's dead code detection (many have built-in support)
- This is a known limitation and may be addressed in future Metastatic updates

## Performance Issues

### Slow Dead Code Analysis

**Symptom:** Dead code analysis takes a long time on large codebases.

**Solutions:**

1. **Disable for large codebases:**
   ```elixir
   config :ragex, :analysis, enable_dead_code_detection: false
   ```

2. **Analyze specific modules only:**
   ```elixir
   DeadCode.find_in_module(MyModule)
   ```

3. **Exclude test modules:**
   ```elixir
   DeadCode.find_unused_exports(exclude_tests: true)
   ```

4. **Increase confidence threshold:**
   ```elixir
   # Only high-confidence results
   DeadCode.find_unused_exports(min_confidence: 0.9)
   ```

### Memory Usage During Analysis

**Symptom:** High memory usage during directory analysis.

**Solution:**
1. Analyze in smaller batches
2. Use `recursive: false` and manually traverse subdirectories
3. Clear the knowledge graph between batches if needed

## Getting Help

If you encounter issues not covered here:

1. Check the [README.md](README.md) for general usage
2. Review the [ANALYSIS.md](stuff/docs/ANALYSIS.md) documentation
3. Check configuration in [CONFIGURATION.md](stuff/docs/CONFIGURATION.md)
4. Open an issue on GitHub with:
   - Error message (full text)
   - Configuration (sanitized)
   - Minimal reproduction case
   - Ragex version (`mix ragex.version` or check `mix.exs`)
