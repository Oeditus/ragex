# Ragex Automated Refactoring Suggestions

Comprehensive guide to Ragex's automated refactoring suggestion engine (Phase 11G).

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Refactoring Patterns](#refactoring-patterns)
4. [Priority Ranking](#priority-ranking)
5. [Action Plans](#action-plans)
6. [RAG Integration](#rag-integration)
7. [MCP Tools](#mcp-tools)
8. [Usage Examples](#usage-examples)
9. [Best Practices](#best-practices)

## Overview

The automated refactoring suggestion engine analyzes your codebase to identify improvement opportunities by combining:

- **Code duplication detection** (Type I-IV clones via Metastatic)
- **Dead code detection** (interprocedural + intraprocedural)
- **Quality metrics** (complexity, coupling, instability)
- **Impact analysis** (risk scoring, effort estimation)
- **Dependency analysis** (circular dependencies, god modules)

Each suggestion includes:
- **Pattern type** (extract_function, split_module, etc.)
- **Priority level** (critical, high, medium, low, info)
- **Actionable plan** with step-by-step instructions
- **RAG-powered advice** (optional, AI-generated context-aware guidance)

## Architecture

```
Target Code (file/module/directory)
         ↓
[Analysis] → Duplication, Dead Code, Quality, Coupling, Impact
         ↓
[Pattern Detection] → 9 refactoring patterns with confidence scores
         ↓
[Priority Ranking] → Score and classify by priority (5 levels)
         ↓
[Action Generation] → Executable plans using MCP tools
         ↓
[RAG Integration] → Optional AI-powered advice
         ↓
Prioritized Suggestions with Action Plans
```

### Core Components

1. **Suggestion Engine** (`Ragex.Analysis.Suggestions`)
   - Orchestrates the entire analysis pipeline
   - Main entry point: `analyze_target/2`

2. **Pattern Detectors** (`Ragex.Analysis.Suggestions.Patterns`)
   - Detects 9 refactoring patterns
   - Returns raw suggestions with confidence scores

3. **Priority Ranker** (`Ragex.Analysis.Suggestions.Ranker`)
   - Scores suggestions using multi-factor algorithm
   - Classifies into 5 priority levels

4. **Action Generator** (`Ragex.Analysis.Suggestions.Actions`)
   - Generates step-by-step refactoring plans
   - Maps to existing MCP tools

5. **RAG Advisor** (`Ragex.Analysis.Suggestions.RAGAdvisor`)
   - Generates AI-powered context-aware advice
   - Pattern-specific prompts

## Refactoring Patterns

### 1. Extract Function

**Detects:** Long functions, duplicate code blocks

**Triggers:**
- Cyclomatic complexity > 15 AND lines of code > 30
- OR lines of code > 50
- Code duplication similarity > 0.85 (Type I/II clones)

**Example:**
```elixir
# Before (complexity: 20, LOC: 80)
def process_order(order) do
  # 80 lines of mixed validation, calculation, and persistence logic
end

# After
def process_order(order) do
  with {:ok, order} <- validate_order(order),
       {:ok, totals} <- calculate_totals(order),
       {:ok, order} <- persist_order(order) do
    {:ok, order}
  end
end
```

### 2. Inline Function

**Detects:** Trivial wrappers, single-use functions

**Triggers:**
- Lines of code <= 3
- Cyclomatic complexity <= 1

**Example:**
```elixir
# Before
defp add(a, b), do: a + b
def calculate(x, y), do: add(x, y)

# After
def calculate(x, y), do: x + y
```

### 3. Split Module

**Detects:** God modules, low cohesion

**Triggers:**
- Function count > 30
- OR function count > 20 AND instability > 0.8

**Example:**
```elixir
# Before: UserModule (40 functions)
defmodule UserModule do
  # Authentication functions
  # Profile management
  # Notification settings
  # Email preferences
  # Analytics tracking
  # ... 40 functions total
end

# After
defmodule User.Auth do ... end
defmodule User.Profile do ... end
defmodule User.Notifications do ... end
```

### 4. Merge Modules

**Detects:** Similar modules with related functionality

**Status:** Placeholder (requires cross-module semantic analysis)

### 5. Remove Dead Code

**Detects:** Unused functions, unreachable code

**Triggers:**
- Dead code confidence >= 0.7
- No callers found (interprocedural)
- Unreachable after returns (intraprocedural)

**Example:**
```elixir
# Before
defp old_implementation(data) do
  # Never called
end

# After
# Function removed
```

### 6. Reduce Coupling

**Detects:** High-coupling modules, circular dependencies

**Triggers:**
- Efferent coupling > 10 AND instability > 0.8
- Circular dependencies detected

**Example:**
```elixir
# Before: High coupling (Ce=15, I=0.9)
defmodule OrderProcessor do
  alias App.{User, Product, Payment, Shipping, Inventory, 
             Analytics, Notification, Email, SMS, Webhook,
             Logger, Metrics, Cache, Database, Queue}
end

# After: Reduced via dependency injection
defmodule OrderProcessor do
  alias App.{Order, Payment, Fulfillment}
  # Other dependencies injected as configuration
end
```

### 7. Simplify Complexity

**Detects:** High cyclomatic complexity, deep nesting

**Triggers:**
- Cyclomatic complexity >= 15
- OR nesting depth >= 5

**Example:**
```elixir
# Before (complexity: 18, nesting: 6)
def process(data) do
  if data.valid? do
    if data.approved? do
      if data.amount > 100 do
        # deeply nested logic
      end
    end
  end
end

# After (complexity: 8, nesting: 2)
def process(data) do
  with :ok <- validate(data),
       :ok <- check_approval(data),
       :ok <- verify_amount(data) do
    perform_processing(data)
  end
end
```

### 8. Extract Module

**Detects:** Related functions scattered across modules

**Status:** Placeholder (requires semantic analysis)

### 9. Introduce FSM

**Detects:** Imperative status/state management patterns that should be modeled as a finite state machine.

**Triggers:**
- Business logic issues from `ImperativeStatusHandling` analyzer (Metastatic)
- 3+ distinct status values detected (branching/assignment/schema)
- OR 2+ status values with 2+ transition-verb functions (`activate`, `archive`, etc.)

**Output includes:**
- Detected states and transition functions
- Generated Mermaid state diagram
- Generated Finitomata module skeleton
- Confidence score based on evidence tiers (branching, assignment, transition verbs)

**Example:**
```elixir
# Before (imperative status management)
defmodule MyApp.Order do
  schema "orders" do
    field :status, Ecto.Enum, values: [:draft, :pending, :paid, :shipped]
  end

  def submit(order), do: put_change(order, :status, :pending)
  def pay(order), do: put_change(order, :status, :paid)
  def ship(order), do: put_change(order, :status, :shipped)
end

# After (FSM - generated skeleton)
defmodule MyApp.OrderFSM do
  @fsm """
  draft --> |submit| pending
  pending --> |pay| paid
  paid --> |ship| shipped
  """

  use Finitomata, fsm: @fsm, syntax: :flowchart

  @impl Finitomata
  def on_transition(:draft, :submit, _payload, state),
    do: {:ok, :pending, state}

  def on_transition(:pending, :pay, _payload, state),
    do: {:ok, :paid, state}

  def on_transition(:paid, :ship, _payload, state),
    do: {:ok, :shipped, state}
end
```

## Priority Ranking

### Scoring Algorithm

Priority score = (benefit × 0.4) + (impact × 0.2) - (risk × 0.2) - (effort × 0.1) + (confidence × 0.1)

**Factors:**
- **Benefit** (40%): Expected improvement (complexity reduction, duplication removal)
- **Impact** (20%): Scope of change (affected files/modules) - logarithmic scale
- **Risk** (-20%): Likelihood of introducing bugs (low: 0.2, medium: 0.5, high: 0.8)
- **Effort** (-10%): Time/complexity to implement
- **Confidence** (10%): Confidence in the detection

### Priority Levels

| Priority | Score Range | Description |
|----------|-------------|-------------|
| **Critical** | > 0.8 | Must address soon, high-impact issues |
| **High** | > 0.6 | Important improvements with good ROI |
| **Medium** | > 0.4 | Beneficial but not urgent |
| **Low** | > 0.2 | Optional improvements |
| **Info** | ≤ 0.2 | For awareness only |

### Pattern-Specific Adjustments

- **remove_dead_code**: +0.1 boost (easy wins)
- **simplify_complexity**: +0.05 boost (high benefit)
- **split_module**: -0.05 penalty (high effort)

### ROI Calculation

ROI = Benefit / Effort

Higher ROI indicates better return for effort invested.

## Action Plans

Each suggestion includes an executable action plan with:

### Structure

```elixir
%{
  suggestion_id: "abc123",
  pattern: :extract_function,
  steps: [
    %{order: 1, action: "Analyze impact", tool: "analyze_impact", params: %{...}, estimated_time: "30 seconds"},
    %{order: 2, action: "Identify code blocks", tool: nil, estimated_time: "5-10 minutes"},
    %{order: 3, action: "Preview extraction", tool: "preview_refactor", params: %{...}, estimated_time: "1 minute"},
    %{order: 4, action: "Apply refactoring", tool: "advanced_refactor", params: %{...}, estimated_time: "30 seconds"},
    %{order: 5, action: "Run tests", command: "mix test", estimated_time: "1-5 minutes"}
  ],
  total_steps: 5,
  estimated_total_time: "30-60 minutes",
  validation: ["Run mix format", "Run mix test", "Review changed files"],
  rollback: ["Use undo_refactor MCP tool", "Or use git revert"]
}
```

### MCP Tool Integration

Action plans map to existing MCP tools:
- `analyze_impact` - Impact analysis
- `preview_refactor` - Preview with diffs
- `advanced_refactor` - Execute refactoring
- `undo_refactor` - Rollback changes
- `analyze_quality` - Quality metrics
- `find_duplicates` - Duplication detection

## RAG Integration

### AI-Powered Advice

When `use_rag: true`, the engine generates context-aware advice using the RAG pipeline:

1. **Pattern-Specific Prompts** - Tailored to each refactoring type
2. **Context Retrieval** - Finds similar patterns in your codebase
3. **AI Generation** - Produces concrete, actionable advice
4. **Fallback** - Direct AI generation if no retrieval results

### Example RAG Advice

```
For extract_function with complexity 18:

"Extract the validation logic (lines 45-60) into validate_input/1. 
This function should:
- Take the raw input map
- Return {:ok, validated} or {:error, reason}
- Handle the email format check and required fields

Consider also extracting the calculation logic (lines 75-95) into 
calculate_totals/1 to further reduce complexity."
```

### Configuration

```elixir
# Enable RAG advice
{:ok, result} = Suggestions.analyze_target(target, use_rag: true)

# Configure provider/temperature
{:ok, result} = Suggestions.analyze_target(target, 
  use_rag: true,
  provider: :deepseek,
  temperature: 0.7
)
```

## MCP Tools

### suggest_refactorings

Analyzes code and generates prioritized refactoring suggestions.

**Parameters:**
- `target` (required): File path, directory, or module name
- `patterns` (optional): Filter by specific patterns
- `min_priority` (optional): Minimum priority level (default: "low")
- `include_actions` (optional): Include action plans (default: true)
- `use_rag` (optional): Use RAG for AI advice (default: false)
- `format` (optional): Output format - "summary", "detailed", "json" (default: "summary")

**Examples:**

```json
{
  "name": "suggest_refactorings",
  "arguments": {
    "target": "lib/my_module.ex",
    "min_priority": "high",
    "include_actions": true,
    "format": "detailed"
  }
}
```

```json
{
  "name": "suggest_refactorings",
  "arguments": {
    "target": "lib/",
    "patterns": ["extract_function", "simplify_complexity"],
    "use_rag": true,
    "format": "json"
  }
}
```

### explain_suggestion

Provides detailed explanation for a specific suggestion.

**Status:** Stub implementation (requires suggestion state management)

## Usage Examples

### Elixir API

```elixir
alias Ragex.Analysis.Suggestions

# Analyze a module
{:ok, result} = Suggestions.analyze_target({:module, MyModule})

IO.puts("Found #{length(result.suggestions)} suggestions")
IO.puts("High priority: #{result.summary.by_priority[:high] || 0}")

# Analyze a file
{:ok, result} = Suggestions.analyze_target("lib/my_module.ex")

# Analyze a directory
{:ok, result} = Suggestions.analyze_target("lib/", 
  recursive: true,
  min_priority: :high
)

# Filter by patterns
{:ok, result} = Suggestions.analyze_target(target,
  patterns: [:extract_function, :simplify_complexity]
)

# With RAG advice
{:ok, result} = Suggestions.analyze_target(target,
  use_rag: true,
  include_actions: true
)

# Process suggestions
Enum.each(result.suggestions, fn sugg ->
  IO.puts("[#{sugg.priority}] #{sugg.pattern}: #{sugg.reason}")
  IO.puts("  Confidence: #{sugg.confidence}")
  IO.puts("  Benefit: #{sugg.benefit}")
  
  if sugg.action_plan do
    IO.puts("  Steps: #{sugg.action_plan.total_steps}")
  end
  
  if sugg.rag_advice do
    IO.puts("  AI Advice: #{sugg.rag_advice}")
  end
end)
```

### Pattern-Specific Analysis

```elixir
# Focus on complexity issues
{:ok, suggestions} = Suggestions.suggest_for_pattern(
  "lib/",
  :simplify_complexity
)

# Focus on dead code
{:ok, suggestions} = Suggestions.suggest_for_pattern(
  {:module, MyModule},
  :remove_dead_code
)
```

## Best Practices

### When to Use Suggestions

1. **Before major refactoring** - Get prioritized recommendations
2. **During code review** - Identify improvement opportunities
3. **After adding features** - Check for introduced complexity
4. **Regular maintenance** - Monthly codebase health checks

### Interpreting Results

1. **Start with critical/high priority** - Focus on highest ROI
2. **Review confidence scores** - Higher confidence = more reliable
3. **Check impact analysis** - Understand scope before refactoring
4. **Read RAG advice** - Get context-specific guidance
5. **Follow action plans** - Step-by-step instructions minimize risk

### Applying Suggestions

1. **One at a time** - Don't apply multiple suggestions simultaneously
2. **Run tests** - After each refactoring
3. **Use preview mode** - Check diffs before applying
4. **Commit frequently** - Easy rollback if needed
5. **Keep backups** - Atomic operations create automatic backups

### False Positives

Some suggestions may not apply:

- **Callbacks mistaken for dead code** - Check confidence score
- **Intentional coupling** - Architectural decisions
- **Generated code** - May have high complexity by design
- **Performance-critical code** - Optimization over readability

Use your judgment and domain knowledge to filter suggestions.

### Performance Considerations

- **Large codebases** - Analyze specific modules first
- **RAG advice** - Adds 2-3 seconds per suggestion
- **Action plans** - Minimal overhead
- **Caching** - Analysis results not cached (run on demand)

## Advanced Usage

### Custom Priority Filtering

```elixir
{:ok, result} = Suggestions.analyze_target(target)

# Filter by custom criteria
high_roi = result.suggestions
|> Enum.filter(fn s -> Ranker.calculate_roi(s) > 2.0 end)
|> Enum.sort_by(&(&1.priority_score), :desc)

# Filter by pattern and priority
complexity_issues = result.suggestions
|> Enum.filter(fn s -> 
  s.pattern == :simplify_complexity and 
  s.priority in [:critical, :high]
end)
```

### Batch Processing

```elixir
# Analyze multiple modules
modules = [MyModule1, MyModule2, MyModule3]

results = Enum.map(modules, fn mod ->
  {:ok, result} = Suggestions.analyze_target({:module, mod})
  {mod, result}
end)

# Aggregate statistics
total_suggestions = results
|> Enum.reduce(0, fn {_mod, result}, acc -> 
  acc + result.summary.total 
end)
```

### Integration with CI/CD

```bash
# Example: Fail build if critical suggestions found
mix ragex.analyze lib/ --format=json > suggestions.json

# Parse JSON and check for critical priority
# (Implementation depends on your CI system)
```

## Troubleshooting

### No Suggestions Found

- Codebase may already be well-structured
- Try lowering `min_priority` to `:info`
- Check that files are analyzed and in knowledge graph

### Low Confidence Scores

- Patterns detected but low certainty
- Review manually before applying
- Consider false positive

### RAG Advice Not Generated

- Check AI provider is configured
- Verify embeddings are generated
- May fail silently if provider unavailable

### Action Plan Errors

- Ensure MCP tools are available
- Check that refactoring operations are supported
- Some plans require manual steps

## See Also

- [ANALYSIS.md](./ANALYSIS.md) - Code analysis capabilities
- [ALGORITHMS.md](./ALGORITHMS.md) - Graph algorithms
- [STREAMING.md](./STREAMING.md) - RAG streaming responses

---

**Phase 11G Complete** - January 23, 2026
