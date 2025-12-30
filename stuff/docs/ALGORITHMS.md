# Ragex Graph Algorithms

This document covers the graph algorithms available in Ragex for analyzing code structure, relationships, and importance metrics.

## Table of Contents

- [Overview](#overview)
- [PageRank](#pagerank)
- [Path Finding](#path-finding)
- [Centrality Metrics](#centrality-metrics)
- [Graph Statistics](#graph-statistics)
- [Usage Examples](#usage-examples)
- [Performance Characteristics](#performance-characteristics)

## Overview

Ragex implements several graph algorithms for analyzing code relationships:

| Algorithm | Purpose | Use Cases |
|-----------|---------|-----------|
| **PageRank** | Importance scoring | Finding central/critical functions |
| **Path Finding** | Dependency chains | Understanding call flows, impact analysis |
| **Degree Centrality** | Connection metrics | Identifying highly-coupled code |
| **Graph Stats** | Overall analysis | Codebase health, complexity assessment |

All algorithms operate on the call graph built from code analysis.

## PageRank

### What It Does

PageRank measures the importance of functions and modules based on who calls them. Functions called by many other functions score higher.

### Algorithm

Based on Google's PageRank algorithm:
- Iterative computation with damping factor
- Higher scores = more important nodes
- Considers both incoming edges and importance of callers

### Usage

```elixir
alias Ragex.Graph.Algorithms

# Basic usage (with defaults)
scores = Algorithms.pagerank()

# Returns: %{
#   {:function, :ModuleA, :foo, 0} => 0.234,
#   {:function, :ModuleB, :bar, 1} => 0.189,
#   ...
# }
```

### Options

```elixir
Algorithms.pagerank(
  damping_factor: 0.85,    # Probability of following edges (default: 0.85)
  max_iterations: 100,     # Maximum iterations (default: 100)
  tolerance: 0.0001        # Convergence threshold (default: 0.0001)
)
```

### Parameters Explained

**damping_factor (0.85):**
- Probability a random walker follows an edge vs. teleporting
- Higher = more weight on graph structure
- Lower = more equal distribution
- Range: 0.0 to 1.0
- Typical values: 0.85 (Google), 0.5 (more distributed)

**max_iterations (100):**
- Maximum number of iterations before stopping
- Prevents infinite loops
- Usually converges in 10-50 iterations
- Increase for very large graphs

**tolerance (0.0001):**
- Convergence threshold
- Stops when maximum score change < tolerance
- Lower = more precise, slower
- Higher = less precise, faster

### Interpretation

**High PageRank (>0.5):**
- Critical functions called by many others
- Central to the codebase
- Changes here have wide impact
- Examples: utility functions, core APIs

**Medium PageRank (0.1-0.5):**
- Moderately important functions
- Called by several others
- Standard application logic

**Low PageRank (<0.1):**
- Leaf functions (few callers)
- Application entry points
- Specialized utilities

### Example Results

```elixir
scores = Algorithms.pagerank()

# Get top 10 most important functions
top = scores
  |> Enum.sort_by(fn {_id, score} -> -score end)
  |> Enum.take(10)

# Results might look like:
# [
#   {{:function, :Utils, :parse_json, 1}, 0.456},  # Called everywhere
#   {{:function, :Core, :process, 2}, 0.389},      # Central processor
#   {{:function, :DB, :query, 1}, 0.234},          # Database access
#   ...
# ]
```

### Performance

- **Time Complexity**: O(iterations × edges)
- **Space Complexity**: O(nodes)
- **Typical Runtime**: <100ms for 1,000 nodes

## Path Finding

### What It Does

Finds all paths between two nodes in the call graph. Useful for understanding how one function reaches another through calls.

### Algorithm

Depth-first search (DFS) with:
- Cycle detection (via visited set)
- Depth limiting
- **Path count limiting** (Phase 4D)
- **Early stopping** when limits reached
- **Dense graph warnings**

### Basic Usage

```elixir
alias Ragex.Graph.Algorithms

# Find paths from function A to function B
paths = Algorithms.find_paths(
  {:function, :ModuleA, :foo, 0},
  {:function, :ModuleC, :baz, 0}
)

# Returns: [
#   [{:function, :ModuleA, :foo, 0}, {:function, :ModuleB, :bar, 0}, {:function, :ModuleC, :baz, 0}],
#   [{:function, :ModuleA, :foo, 0}, {:function, :ModuleD, :qux, 0}, {:function, :ModuleC, :baz, 0}]
# ]
```

### Options

```elixir
Algorithms.find_paths(from, to,
  max_depth: 10,        # Maximum path length in edges (default: 10)
  max_paths: 100,       # Maximum paths to return (default: 100)
  warn_dense: true      # Emit warnings for dense graphs (default: true)
)
```

### Parameters Explained

**max_depth (10):**
- Maximum path length measured in edges (hops)
- Path with 3 nodes has 2 edges
- Prevents searching too deep
- Typical values:
  - 5: Direct dependencies only
  - 10: Standard (covers most practical cases)
  - 20: Deep analysis (may be slow)

**max_paths (100):**
- Maximum number of paths to return
- Prevents exponential explosion in dense graphs
- Stops DFS early when reached
- Typical values:
  - 10: Quick analysis
  - 100: Standard (Phase 4D default)
  - 1000: Exhaustive (may hang on dense graphs)

**warn_dense (true):**
- Automatically warn about dense graphs
- Checks starting node's out-degree
- Helpful for understanding performance
- Set to `false` in automated systems

### Dense Graph Warnings

The system automatically detects and warns about potentially slow operations:

**INFO Level (≥10 edges):**
```
Moderately connected node: {:function, :ModuleA, :foo, 0} has 12 outgoing edges.
Path finding may take some time.
```

**WARNING Level (≥20 edges):**
```
Dense graph detected: Node {:function, :HubModule, :central, 0} has 25 outgoing edges.
Path finding may be slow or return partial results. Consider reducing max_depth or max_paths.
```

### Examples

#### 1. Finding Direct Dependencies

```elixir
# Find immediate calls (depth 1)
paths = Algorithms.find_paths(from, to, max_depth: 1)
```

#### 2. Quick Analysis (Limited Paths)

```elixir
# Get just a few example paths
paths = Algorithms.find_paths(from, to, max_paths: 10)
```

#### 3. Deep Dependency Analysis

```elixir
# Explore deeper relationships (careful with dense graphs!)
paths = Algorithms.find_paths(from, to, max_depth: 15, max_paths: 200)
```

#### 4. Silent Operation (No Warnings)

```elixir
# For automated tools
paths = Algorithms.find_paths(from, to, warn_dense: false)
```

#### 5. Checking if Path Exists

```elixir
# Quick check
case Algorithms.find_paths(from, to, max_paths: 1) do
  [] -> :no_path
  [_path] -> :has_path
end
```

### Interpreting Results

**Empty List `[]`:**
- No path exists from source to target
- Functions are independent
- Target not reachable through calls

**Single Path:**
- Direct or unique dependency chain
- Clear relationship

**Multiple Paths:**
- Function is reachable through different routes
- May indicate coupling or complex dependencies
- Consider refactoring if count is very high

**Truncated Results (= max_paths):**
- Many more paths likely exist
- Dense graph structure
- Consider:
  - Reducing max_depth
  - Refactoring to reduce coupling
  - Increasing max_paths if needed

### Performance

| Scenario | Complexity | Typical Time |
|----------|------------|--------------|
| Sparse graph | O(V + E) | <10ms |
| Moderate graph | O(V × D) | 10-100ms |
| Dense graph (no limit) | O(V^D) | Hang risk! |
| Dense graph (with limit) | O(max_paths × D) | <200ms |

**V** = vertices (nodes), **E** = edges, **D** = max_depth

### Known Limitations

1. **Non-deterministic order**: Path order may vary between runs (DFS traversal order)
2. **No truncation indicator**: Can't tell if results are complete or truncated
3. **Path quality**: All paths treated equally (no shortest-path preference)
4. **Memory usage**: Storing many long paths can consume significant memory

## Centrality Metrics

### What It Does

Computes connection-based metrics for all nodes in the graph.

### Metrics

**In-Degree:**
- Number of incoming edges (callers)
- Functions with high in-degree are called by many others
- Indicates reusability or coupling

**Out-Degree:**
- Number of outgoing edges (callees)
- Functions with high out-degree call many others
- Indicates complexity or coordination role

**Total Degree:**
- Sum of in-degree and out-degree
- Overall connectivity metric

### Usage

```elixir
centrality = Algorithms.degree_centrality()

# Returns: %{
#   {:function, :ModuleA, :foo, 0} => %{
#     in_degree: 0,      # Not called by anyone
#     out_degree: 5,     # Calls 5 other functions
#     total_degree: 5
#   },
#   {:function, :Utils, :helper, 1} => %{
#     in_degree: 12,     # Called by 12 functions
#     out_degree: 2,     # Calls 2 functions
#     total_degree: 14
#   },
#   ...
# }
```

### Interpretation

#### High In-Degree (>10)
- **Utility functions**: Reused across codebase
- **Core APIs**: Central to application logic
- **Potential issues**: Single point of failure, change impact

#### High Out-Degree (>10)
- **Coordinator functions**: Orchestrate multiple operations
- **Complex logic**: May need refactoring
- **Dense nodes**: Path finding may be slow

#### High Total Degree (>20)
- **Hub nodes**: Central to the graph
- **Critical code**: Changes affect many paths
- **Refactoring target**: Consider splitting

### Example Analysis

```elixir
centrality = Algorithms.degree_centrality()

# Find functions called by many (utilities)
utilities = centrality
  |> Enum.filter(fn {_id, metrics} -> metrics.in_degree > 10 end)
  |> Enum.sort_by(fn {_id, metrics} -> -metrics.in_degree end)

# Find complex coordinators
coordinators = centrality
  |> Enum.filter(fn {_id, metrics} -> metrics.out_degree > 15 end)
  |> Enum.sort_by(fn {_id, metrics} -> -metrics.out_degree end)
```

## Graph Statistics

### What It Does

Provides comprehensive overview of the entire codebase graph structure.

### Usage

```elixir
stats = Algorithms.graph_stats()

# Returns: %{
#   node_count: 1234,
#   node_counts_by_type: %{
#     function: 1000,
#     module: 100,
#     call: 3000
#   },
#   edge_count: 3000,
#   average_degree: 4.86,
#   density: 0.0024,
#   top_nodes: [
#     {{:function, :Utils, :parse, 1}, 0.234},
#     {{:function, :Core, :run, 0}, 0.189},
#     ...
#   ]
# }
```

### Metrics Explained

**node_count:**
- Total number of nodes (modules, functions, calls)
- Larger = bigger codebase

**node_counts_by_type:**
- Breakdown by entity type
- Useful for understanding code composition

**edge_count:**
- Total number of call relationships
- Indicates coupling level

**average_degree:**
- Average connections per node
- Higher = more coupled
- Typical values:
  - 2-4: Well-structured, modular
  - 5-10: Moderate coupling
  - >10: High coupling, consider refactoring

**density:**
- Ratio of actual to possible edges
- Range: 0.0 (no edges) to 1.0 (fully connected)
- Typical values:
  - <0.01: Sparse, well-structured
  - 0.01-0.05: Moderate
  - >0.05: Dense, potential issues

**top_nodes:**
- Top 10 functions by PageRank
- Most important/central functions

### Example Interpretation

```elixir
stats = Algorithms.graph_stats()

IO.puts("Codebase Analysis:")
IO.puts("  Total functions: #{stats.node_counts_by_type[:function]}")
IO.puts("  Total calls: #{stats.edge_count}")
IO.puts("  Coupling level: #{stats.average_degree}")

# Health check
cond do
  stats.average_degree < 4 ->
    IO.puts("✓ Well-structured codebase")
  
  stats.average_degree < 8 ->
    IO.puts("⚠ Moderate coupling, consider modularization")
  
  true ->
    IO.puts("⚠ High coupling, refactoring recommended")
end
```

## Usage Examples

### 1. Find Critical Functions

```elixir
# Combine PageRank and centrality
scores = Algorithms.pagerank()
centrality = Algorithms.degree_centrality()

critical_functions = scores
  |> Enum.filter(fn {id, score} ->
    metrics = Map.get(centrality, id, %{in_degree: 0})
    score > 0.2 and metrics.in_degree > 10
  end)
  |> Enum.sort_by(fn {_id, score} -> -score end)

IO.puts("Critical functions that need tests:")
for {id, score} <- critical_functions do
  IO.puts("  #{inspect(id)} - score: #{Float.round(score, 3)}")
end
```

### 2. Impact Analysis

```elixir
# Find all functions affected by a change
changed_function = {:function, :Core, :process, 2}

# Get reverse dependencies (who calls this?)
centrality = Algorithms.degree_centrality()
{:ok, metrics} = Map.fetch(centrality, changed_function)

IO.puts("Direct impact: #{metrics.in_degree} callers")

# Check transitivity by finding paths to entry points
entry_points = find_entry_points()  # Your function

for entry <- entry_points do
  paths = Algorithms.find_paths(changed_function, entry, max_paths: 10)
  unless Enum.empty?(paths) do
    IO.puts("  Affects: #{inspect(entry)} (#{length(paths)} paths)")
  end
end
```

### 3. Detect Code Smells

```elixir
centrality = Algorithms.degree_centrality()

# Find "God functions" (too many responsibilities)
god_functions = centrality
  |> Enum.filter(fn {_id, m} -> m.out_degree > 20 end)

# Find "hub functions" (too many dependencies)
hub_functions = centrality
  |> Enum.filter(fn {_id, m} -> m.in_degree > 30 end)

# Find isolated modules
isolated = centrality
  |> Enum.filter(fn {_id, m} -> m.total_degree == 0 end)

IO.puts("Code health report:")
IO.puts("  God functions: #{length(god_functions)}")
IO.puts("  Hub functions: #{length(hub_functions)}")
IO.puts("  Isolated entities: #{length(isolated)}")
```

### 4. Dependency Chain Visualization

```elixir
# Find all paths and visualize
from = {:function, :API, :handle_request, 1}
to = {:function, :DB, :query, 2}

paths = Algorithms.find_paths(from, to, max_depth: 5)

IO.puts("Request flows from API to Database:")
for path <- paths do
  IO.puts("\n  " <> Enum.map_join(path, " -> ", &format_node/1))
end

defp format_node({:function, module, name, arity}) do
  "#{module}.#{name}/#{arity}"
end
```

### 5. Codebase Evolution Tracking

```elixir
# Compare stats over time
stats_before = Algorithms.graph_stats()
# ... make changes ...
stats_after = Algorithms.graph_stats()

IO.puts("Changes:")
IO.puts("  Functions: #{stats_before.node_counts_by_type[:function]} → #{stats_after.node_counts_by_type[:function]}")
IO.puts("  Coupling: #{stats_before.average_degree} → #{stats_after.average_degree}")
IO.puts("  Density: #{stats_before.density} → #{stats_after.density}")

if stats_after.average_degree < stats_before.average_degree do
  IO.puts("✓ Coupling reduced - good refactoring!")
else
  IO.puts("⚠ Coupling increased - review changes")
end
```

## Performance Characteristics

### Computational Complexity

| Algorithm | Time Complexity | Space Complexity | Typical Runtime (1K nodes) |
|-----------|----------------|------------------|----------------------------|
| PageRank | O(I × E) | O(V) | 50-100ms |
| Path Finding (limited) | O(max_paths × D) | O(max_paths × D) | 10-200ms |
| Path Finding (unlimited) | O(V^D) | O(V^D) | Risk of hang! |
| Degree Centrality | O(V + E) | O(V) | <10ms |
| Graph Stats | O(V + E + I × E) | O(V) | 100-150ms |

**Notation:**
- V = vertices (nodes)
- E = edges
- I = PageRank iterations
- D = max_depth

### Memory Usage

| Operation | Memory Footprint | Notes |
|-----------|------------------|-------|
| PageRank | ~100 bytes/node | Score storage |
| Path Finding | ~1KB/path | Path list storage |
| Centrality | ~200 bytes/node | Three metrics per node |
| Graph Stats | ~500 bytes | Aggregated results |

### Optimization Tips

**For Large Graphs (>10K nodes):**

1. **Use limited path finding:**
   ```elixir
   paths = Algorithms.find_paths(from, to, max_paths: 50, max_depth: 8)
   ```

2. **Cache PageRank results:**
   ```elixir
   scores = Algorithms.pagerank()
   # Store in ETS or process state for reuse
   ```

3. **Filter before computing:**
   ```elixir
   # Only compute for functions (not all nodes)
   functions = Store.list_nodes(:function)
   # Then run algorithms on subset
   ```

4. **Use lower precision:**
   ```elixir
   Algorithms.pagerank(tolerance: 0.001)  # Faster convergence
   ```

**For Dense Graphs (high degree):**

1. **Always use max_paths limit:**
   ```elixir
   paths = Algorithms.find_paths(from, to, max_paths: 100)  # Never unlimited!
   ```

2. **Reduce depth:**
   ```elixir
   paths = Algorithms.find_paths(from, to, max_depth: 5)
   ```

3. **Disable warnings in loops:**
   ```elixir
   for target <- targets do
     Algorithms.find_paths(from, target, warn_dense: false)
   end
   ```

## Best Practices

### 1. Always Use Limits

❌ **Don't:**
```elixir
# Dangerous on dense graphs!
paths = Algorithms.find_paths(from, to, max_paths: 10_000)
```

✅ **Do:**
```elixir
# Safe default limits
paths = Algorithms.find_paths(from, to)  # Uses max_paths: 100
```

### 2. Check Graph Health First

```elixir
stats = Algorithms.graph_stats()

if stats.average_degree > 15 do
  IO.puts("Warning: Dense graph detected. Using conservative limits.")
  opts = [max_paths: 50, max_depth: 5]
else
  opts = []  # Use defaults
end

paths = Algorithms.find_paths(from, to, opts)
```

### 3. Interpret Results in Context

```elixir
# Don't just look at numbers - understand the domain
scores = Algorithms.pagerank()

for {{:function, module, name, _arity}, score} <- scores do
  if score > 0.3 and module != :Utils do
    # High score but not a utility - may indicate tight coupling
    IO.puts("Review: #{module}.#{name} has high PageRank but isn't a utility")
  end
end
```

### 4. Combine Multiple Metrics

```elixir
# Use multiple algorithms for better insights
scores = Algorithms.pagerank()
centrality = Algorithms.degree_centrality()

for {{:function, _m, _n, _a} = id, score} <- scores do
  metrics = Map.get(centrality, id)
  
  # High PageRank + Low in-degree = Entry point
  if score > 0.2 and metrics.in_degree < 2 do
    IO.puts("Entry point: #{inspect(id)}")
  end
  
  # High PageRank + High in-degree = Critical utility
  if score > 0.3 and metrics.in_degree > 10 do
    IO.puts("Critical utility: #{inspect(id)}")
  end
end
```

## References

- [PageRank Algorithm](https://en.wikipedia.org/wiki/PageRank)
- [Graph Centrality Metrics](https://en.wikipedia.org/wiki/Centrality)
- [Depth-First Search](https://en.wikipedia.org/wiki/Depth-first_search)
- [Code Coupling Metrics](https://en.wikipedia.org/wiki/Coupling_(computer_programming))

---

**Related Documentation:**
- [README.md](README.md) - Project overview
- [PERSISTENCE.md](PERSISTENCE.md) - Caching and persistence
- [CONFIGURATION.md](CONFIGURATION.md) - Model and cache configuration
