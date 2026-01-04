# Ragex MCP Prompts

Prompts are high-level workflow templates that compose multiple Ragex tools into guided analysis tasks. They provide structured instructions that help LLMs leverage Ragex's hybrid RAG capabilities effectively.

## Overview

Prompts enable LLMs to:
- Perform complex multi-step analyses with clear guidance
- Discover and use appropriate Ragex tools for specific tasks
- Follow best practices for code analysis workflows
- Provide consistent, structured results

## Available Prompts

### 1. Analyze Architecture (`analyze_architecture`)

Performs comprehensive architectural analysis of a codebase.

**Arguments:**
- `path` (required): Path to the directory or file to analyze
- `depth` (optional): Analysis depth
  - `"shallow"` - Quick overview with graph statistics
  - `"deep"` - Detailed analysis with community detection and centrality metrics

**Suggested Tools:**
- Shallow: `analyze_directory`, `graph_stats`
- Deep: `analyze_directory`, `detect_communities`, `betweenness_centrality`, `graph_stats`

**Example Usage:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "prompts/get",
  "params": {
    "name": "analyze_architecture",
    "arguments": {
      "path": "/project/lib",
      "depth": "deep"
    }
  }
}
```

**Output Guidance:**
- Architectural structure and modularity assessment
- Key modules and their relationships
- Potential coupling issues
- Critical functions that act as bridges

---

### 2. Find Impact (`find_impact`)

Analyzes the impact and importance of a specific function.

**Arguments:**
- `module` (required): Module name containing the function
- `function` (required): Function name to analyze
- `arity` (required): Function arity (number of arguments)

**Suggested Tools:**
- `query_graph` (find_function, get_callers)
- `graph_stats` (PageRank importance)
- `find_paths` (trace from entry points)

**Example Usage:**
```json
{
  "name": "find_impact",
  "arguments": {
    "module": "MyApp.Core",
    "function": "process",
    "arity": 2
  }
}
```

**Output Guidance:**
- Impact radius (number of callers)
- Importance score (PageRank)
- Affected modules
- Refactoring risk assessment
- Whether function is architecturally critical

---

### 3. Explain Code Flow (`explain_code_flow`)

Explains execution flow between two functions with narrative description.

**Arguments:**
- `from_function` (required): Starting function (format: `Module.function/arity`)
- `to_function` (required): Target function (format: `Module.function/arity`)
- `context_lines` (optional): Number of context lines (default: 3)

**Suggested Tools:**
- `find_paths` (discover call chains)
- `query_graph` (get function details)
- `semantic_search` (find related documentation)

**Example Usage:**
```json
{
  "name": "explain_code_flow",
  "arguments": {
    "from_function": "MyApp.Web.Controller.index/2",
    "to_function": "MyApp.DB.Query.fetch/1",
    "context_lines": "5"
  }
}
```

**Output Guidance:**
- Number of different paths between functions
- Step-by-step explanation of most direct path
- What each intermediate function does
- Alternative paths and when they're taken
- Overall execution flow context

---

### 4. Find Similar Code (`find_similar_code`)

Finds code similar to a natural language description using hybrid search.

**Arguments:**
- `description` (required): Natural language description of code to find
- `file_type` (optional): File type filter (e.g., `"elixir"`, `"python"`)
- `top_k` (optional): Number of results to return (default: 5)

**Suggested Tools:**
- `hybrid_search` (semantic + graph search)
- `query_graph` (detailed match information)

**Example Usage:**
```json
{
  "name": "find_similar_code",
  "arguments": {
    "description": "function that validates user input and returns errors",
    "file_type": "elixir",
    "top_k": "3"
  }
}
```

**Output Guidance:**
- Similarity score for each match
- File location and function name
- Why each result matches
- Code snippets showing implementation
- Which result best matches intent

---

### 5. Suggest Refactoring (`suggest_refactoring`)

Analyzes code and suggests refactoring opportunities.

**Arguments:**
- `target_path` (required): Path to code to analyze
- `focus` (optional): Refactoring focus
  - `"modularity"` - Module structure analysis (default)
  - `"coupling"` - Dependency analysis
  - `"complexity"` - Hotspot identification

**Suggested Tools:**
- `analyze_directory` (build knowledge graph)
- `detect_communities` (identify coupling patterns)
- `betweenness_centrality` (find bottlenecks)
- `graph_stats` (overall metrics)

**Example Usage:**
```json
{
  "name": "suggest_refactoring",
  "arguments": {
    "target_path": "/project/lib/my_app",
    "focus": "coupling"
  }
}
```

**Output Guidance:**
- Specific functions/modules needing attention
- Why they're problematic
- Concrete refactoring actions
- Priority level (high/medium/low) based on metrics
- Potential refactoring risks

---

### 6. Safe Rename (`safe_rename`)

Previews and optionally performs safe semantic renaming.

**Arguments:**
- `type` (required): Entity type (`"function"` or `"module"`)
- `old_name` (required): Current name
- `new_name` (required): New name
- `scope` (optional): Rename scope
  - `"module"` - Current module only
  - `"project"` - Project-wide (default)

**Suggested Tools:**
- `query_graph` (verify entity exists)
- `graph_stats` (calculate impact)
- `refactor_code` (execute rename)

**Example Usage:**
```json
{
  "name": "safe_rename",
  "arguments": {
    "type": "function",
    "old_name": "process_data",
    "new_name": "transform_data",
    "scope": "project"
  }
}
```

**Output Guidance:**
- Whether entity exists and can be renamed
- Number of files affected
- Impact on other modules
- Potential naming conflicts
- Risk level (low/medium/high)
- Ask user before executing with `refactor_code`

---

## Workflow Patterns

### Sequential Analysis
For deep architectural analysis:
1. Use `analyze_architecture` (deep) for overview
2. Use `suggest_refactoring` on problem areas
3. Use `find_impact` on critical functions
4. Use `safe_rename` for approved refactorings

### Code Discovery
For finding existing implementations:
1. Use `find_similar_code` with description
2. Use `explain_code_flow` to understand execution
3. Use `find_impact` to assess reuse safety

### Impact Assessment
Before making changes:
1. Use `find_impact` on target function
2. Use `explain_code_flow` to trace dependencies
3. Use `safe_rename` to preview changes

## Best Practices

### 1. Start Broad, Then Narrow
- Begin with `analyze_architecture` for overview
- Drill down with specific prompts
- Use focused tools for detailed investigation

### 2. Validate Before Acting
- Use `safe_rename` preview before actual rename
- Check `find_impact` before major refactoring
- Verify paths with `explain_code_flow`

### 3. Combine Semantic and Structural
- Use `find_similar_code` for discovery
- Follow up with graph queries for structure
- Leverage hybrid search capabilities

### 4. Monitor Cache
- Check `cache/status` resource before large analyses
- Refresh embeddings if many files changed
- Validate model readiness with `model/config`

## Integration with Tools

Prompts suggest tools but don't execute them. The LLM should:
1. Read the prompt instructions
2. Execute suggested tools in sequence
3. Synthesize results according to output guidance
4. Present findings to user

Example flow for `analyze_architecture`:
```
1. LLM receives prompt
2. LLM calls analyze_directory tool
3. LLM calls detect_communities tool
4. LLM calls betweenness_centrality tool
5. LLM calls graph_stats tool
6. LLM synthesizes results into architectural summary
```

## Error Handling

If a prompt cannot be executed:
- Missing required arguments → Return validation error
- Invalid entity references → Check existence first with query_graph
- Empty results → Suggest analyzing directory first
- Model not ready → Check model/config resource

## Performance Considerations

| Prompt | Typical Duration | Complexity |
|--------|-----------------|------------|
| `analyze_architecture` (shallow) | 10-30s | Low |
| `analyze_architecture` (deep) | 30-120s | High |
| `find_impact` | 5-15s | Medium |
| `explain_code_flow` | 10-30s | Medium |
| `find_similar_code` | 5-20s | Medium |
| `suggest_refactoring` | 30-90s | High |
| `safe_rename` | 10-40s | Medium |

Times depend on codebase size and whether embeddings are cached.

## Examples

### Full Architectural Review

```json
// Step 1: Deep analysis
{"name": "analyze_architecture", "arguments": {"path": "/project/lib", "depth": "deep"}}

// Step 2: Focus on modularity issues
{"name": "suggest_refactoring", "arguments": {"target_path": "/project/lib", "focus": "modularity"}}

// Step 3: Assess impact of critical function
{"name": "find_impact", "arguments": {"module": "Core", "function": "main", "arity": 1}}
```

### Safe Refactoring Workflow

```json
// Step 1: Find what needs renaming
{"name": "find_similar_code", "arguments": {"description": "inconsistent naming pattern"}}

// Step 2: Check impact
{"name": "find_impact", "arguments": {"module": "Utils", "function": "old_name", "arity": 2}}

// Step 3: Preview rename
{"name": "safe_rename", "arguments": {"type": "function", "old_name": "old_name", "new_name": "new_name"}}
```

## See Also

- [RESOURCES.md](RESOURCES.md) - Read-only state access
- [README.md](README.md) - Tool reference
- [ALGORITHMS.md](ALGORITHMS.md) - Algorithm details
