# Metastatic Full Integration Roadmap

**Date**: January 24, 2026  
**Status**: Phase 2 Complete  
**Estimated Total Effort**: 3.5 weeks

## Progress Tracker

- [x] Phase 0: Analysis & Planning (Complete - See METASTATIC_UNTAPPED_CAPABILITIES.md)
- [x] **Phase 1: Security Analysis (Complete - January 24, 2026)**
- [x] **Phase 2: Enhanced Complexity (Complete - January 24, 2026)**
- [ ] Phase 3: Code Smells (Not Started - 3 days)
- [ ] Phase 4: Cohesion Analysis (Not Started - 4 days)
- [ ] Phase 5: Enhanced Purity (Not Started - 2 days)
- [ ] Phase 6: State Management (Not Started - 3 days)

---

## Phase 1: Security Analysis (1 week) 🔥 CRITICAL

**Status**: Complete  
**Completion**: 100% (January 24, 2026)

### ✅ Completed
1. Created `Ragex.Analysis.Security` module (356 lines)
   - Single file analysis with auto language detection
   - Directory scanning (parallel/sequential with configurable concurrency)
   - Audit report generation with grouping and recommendations
   - CWE-mapped vulnerabilities with severity levels
   - Filtering by severity and category

2. Added 3 MCP security tools
   - `scan_security` - Scan files/directories for vulnerabilities
   - `security_audit` - Generate comprehensive audit reports
   - `check_secrets` - Specialized hardcoded secrets detection

3. Integrated with Quality analysis
   - Added `Quality.comprehensive_report/2` function
   - Combines quality metrics with security scanning
   - Optional security analysis with graceful degradation

4. Created comprehensive test suite
   - 21 tests total, 18 passing (100% of applicable tests)
   - 3 skipped with documented limitations
   - Test fixtures for known vulnerabilities
   - Multi-language test coverage (Elixir, Python, Erlang)

5. Written comprehensive documentation
   - `docs/SECURITY_ANALYSIS.md` (561 lines)
   - API reference, usage examples, CI/CD integration
   - MCP tools documentation
   - Known limitations and troubleshooting

6. Fixed Metastatic Security module bugs
   - Fixed @dangerous_functions map key syntax
   - Added :language_specific tuple support in walk_ast
   - Added defensive pattern matching
   - Improved secret detection patterns

7. Added parser infrastructure
   - Python parser with AST conversion
   - Ruby parser with AST conversion
   - Haskell parser with AST conversion

#### Step 1.2: Add MCP Security Tools (2-3 hours)

Create/update: `lib/ragex/mcp/handlers/tools.ex`

Add three new MCP tools:
```elixir
# 1. scan_security - Scan file/directory for vulnerabilities
{
  "name": "scan_security",
  "description": "Scan for security vulnerabilities",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {"type": "string"},
      "recursive": {"type": "boolean", "default": true},
      "min_severity": {"type": "string", "enum": ["low", "medium", "high", "critical"]}
    }
  }
}

# 2. security_audit - Generate comprehensive security audit report
{
  "name": "security_audit",
  "description": "Generate security audit report for project",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {"type": "string"},
      "format": {"type": "string", "enum": ["json", "markdown", "text"]}
    }
  }
}

# 3. check_secrets - Check for hardcoded secrets
{
  "name": "check_secrets",
  "description": "Check for hardcoded secrets in code",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {"type": "string"}
    }
  }
}
```

Implementation:
- Add tool definitions to `list_tools/0`
- Add handler clauses to `call_tool/2`
- Format results as MCP responses

#### Step 1.3: Integrate with Quality Analysis (3-4 hours)

Update: `lib/ragex/analysis/metastatic_bridge.ex`

Add security analysis:
```elixir
def analyze_file(path, opts \\\\ []) do
  # ... existing code ...
  
  # Add security analysis
  {:ok, security_result} <- analyze_security(doc, metrics)
  
  # Include in result
  {:ok, build_result(path, language, complexity_result, purity_result, security_result)}
end

defp analyze_security(doc, metrics) do
  if metrics == :all or :security in metrics do
    case Metastatic.Analysis.Security.analyze(doc) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:ok, nil}  # Graceful degradation
    end
  else
    {:ok, nil}
  end
end
```

Update `QualityStore` to store security results.

#### Step 1.4: Create Tests (4-5 hours)

Create: `test/analysis/security_test.exs`

Test coverage:
```elixir
defmodule Ragex.Analysis.SecurityTest do
  use ExUnit.Case, async: true
  
  describe "analyze_file/2" do
    test "detects eval in Elixir code"
    test "detects System.cmd in Elixir code"
    test "detects hardcoded secrets"
    test "handles files with no vulnerabilities"
    test "handles invalid files gracefully"
  end
  
  describe "analyze_directory/2" do
    test "scans directory recursively"
    test "uses parallel processing"
    test "filters by severity"
  end
  
  describe "audit_report/1" do
    test "generates summary"
    test "groups by severity"
    test "groups by category"
    test "generates recommendations"
  end
end
```

Create test fixtures with known vulnerabilities.

#### Step 1.5: Documentation (2-3 hours)

Create: `docs/SECURITY_ANALYSIS.md`

Content:
- Overview of security scanning
- Supported vulnerability types
- CWE mapping
- Usage examples
- MCP tool documentation
- Integration guide
- Best practices

---

## Phase 2: Enhanced Complexity (3 days)

**Status**: Complete  
**Completion**: 100% (January 24, 2026)

**Objective**: Replace our simplified complexity metrics with full Metastatic.Analysis.Complexity

### ✅ Completed

1. **Updated Metastatic Analyzer** (`lib/ragex/analyzers/metastatic.ex`)
   - Replaced custom `calculate_complexity/1`, `calculate_halstead/1`, `calculate_loc/1` functions
   - Now uses `Metastatic.Analysis.Complexity.analyze/2` directly
   - Provides comprehensive metrics:
     - Cyclomatic complexity (McCabe metric)
     - Cognitive complexity (structural with nesting penalties)
     - Maximum nesting depth
     - Enhanced Halstead metrics (volume, difficulty, effort, vocabulary, length)
     - Detailed LoC (physical, logical, comments, blank)
     - Function-level metrics (statement_count, return_points, variable_count, parameter_count)
   - Graceful fallback to basic metrics if analysis fails
   - Updated module documentation to reflect new capabilities

2. **MetastaticBridge Already Compatible**
   - No changes needed - `format_complexity/1` already handles all Result fields
   - Supports `per_function` metrics array
   - Preserves warnings and summary from Complexity.Result

3. **Updated Tests** (`test/analyzers/metastatic_enrichment_test.exs`)
   - Updated structure expectations: flat metrics instead of nested
   - Now checks for `cyclomatic`, `cognitive`, `max_nesting`, `halstead`, `loc`, `function_metrics`
   - All tests passing (818 total, 0 failures, 28 skipped)

4. **Updated Documentation** (`README.md`)
   - Expanded Quality Metrics section with detailed breakdown
   - Documented all complexity metrics with formulas
   - Added comprehensive Halstead metrics explanation
   - Detailed LoC breakdown (physical, logical, comments, blank)
   - Function metrics documentation

### Implementation Details

**Before (Simplified Custom Metrics):**
```elixir
%{
  complexity: %{cyclomatic: 3, decision_points: 2},
  purity: %{pure: false, side_effects: [:io_or_mutation]},
  halstead: %{unique_operators: 5, unique_operands: 3, vocabulary: 8},
  loc: %{expressions: 4, estimated: 4}
}
```

**After (Full Metastatic Complexity):**
```elixir
%{
  cyclomatic: 3,
  cognitive: 2,
  max_nesting: 1,
  halstead: %{
    distinct_operators: 5,
    distinct_operands: 3,
    total_operators: 8,
    total_operands: 6,
    vocabulary: 8,
    length: 14,
    volume: 50.0,
    difficulty: 2.5,
    effort: 125.0
  },
  loc: %{
    physical: 10,
    logical: 8,
    comments: 2,
    blank: 0
  },
  function_metrics: %{
    statement_count: 8,
    return_points: 1,
    variable_count: 3,
    parameter_count: 2
  }
}
```

### Step 2.1: Update Analyzer Enrichment (4-6 hours)

Update: `lib/ragex/analyzers/metastatic.ex`

Replace `calculate_complexity/1` and related functions:
```elixir
defp calculate_function_metrics(ast_node) do
  # Create document for this function's AST
  doc = Document.new(ast_node, :elixir)
  
  # Use full Metastatic complexity analysis
  {:ok, complexity} = Metastatic.Analysis.Complexity.analyze(doc)
  
  %{
    complexity: %{
      cyclomatic: complexity.cyclomatic,
      cognitive: complexity.cognitive,       # NEW
      max_nesting: complexity.max_nesting,   # ENHANCED
      decision_points: complexity.cyclomatic - 1
    },
    halstead: complexity.halstead,           # COMPREHENSIVE
    loc: complexity.loc,                     # DETAILED
    function_metrics: complexity.function_metrics  # NEW
  }
end
```

### Step 2.2: Update MetastaticBridge (3-4 hours)

Update: `lib/ragex/analysis/metastatic_bridge.ex`

Enhance complexity analysis to use full Metastatic capabilities.

### Step 2.3: Update Tests (3-4 hours)

Update existing tests to expect new fields.
Add tests for cognitive complexity, enhanced Halstead, detailed LOC.

### Step 2.4: Documentation (2 hours)

Update ALGORITHMS.md and ANALYSIS.md with new metrics.

---

## Phase 3: Code Smells (3 days)

**Objective**: Add code smell detection

### Step 3.1: Create Smells Module (4-5 hours)

Create: `lib/ragex/analysis/smells.ex`

Wrapper around Metastatic.Analysis.Smells with:
- File analysis
- Directory scanning
- Configurable thresholds
- Integration with existing quality system

### Step 3.2: Add MCP Tool (2-3 hours)

Add `detect_smells` MCP tool

### Step 3.3: Integrate with Suggestions (4-5 hours)

Update: `lib/ragex/analysis/suggestions.ex`

Add smell-based refactoring patterns:
- Extract magic numbers to constants
- Split long functions
- Reduce nesting depth

### Step 3.4: Tests & Documentation (4-5 hours)

---

## Phase 4: Cohesion Analysis (4 days)

**Objective**: Add LCOM and TCC/LCC cohesion metrics

### Step 4.1: Create Cohesion Module (5-6 hours)

Create: `lib/ragex/analysis/cohesion.ex`

Note: Cohesion requires `:container` AST nodes (classes/modules with methods).
May need adapter for Elixir modules.

### Step 4.2: Add MCP Tool (2-3 hours)

Add `analyze_cohesion` MCP tool

### Step 4.3: Integrate with Quality (3-4 hours)

Add cohesion metrics to quality reports.

### Step 4.4: Add Refactoring Suggestions (5-6 hours)

Suggest module splits based on LCOM analysis.

### Step 4.5: Tests & Documentation (5-6 hours)

---

## Phase 5: Enhanced Purity (2 days)

**Objective**: Replace custom purity with full Metastatic.Analysis.Purity

### Step 5.1: Update Analyzer Enrichment (3-4 hours)

Replace `analyze_purity/1` in `lib/ragex/analyzers/metastatic.ex`

Use Metastatic.Analysis.Purity.analyze/1 directly.

### Step 5.2: Update MetastaticBridge (2-3 hours)

Use full purity analysis.

### Step 5.3: Tests & Documentation (3-4 hours)

---

## Phase 6: State Management (3 days)

**Objective**: Add state management pattern detection

### Step 6.1: Create StateManagement Module (5-6 hours)

Create: `lib/ragex/analysis/state_management.ex`

Adapter for Elixir GenServers/Agents.

### Step 6.2: Add MCP Tool (2-3 hours)

Add `check_state_management` MCP tool

### Step 6.3: Integrate with Quality (3-4 hours)

### Step 6.4: Tests & Documentation (4-5 hours)

---

## Testing Strategy

### Unit Tests
- Each new module: 10-15 tests
- Coverage target: >90%

### Integration Tests
- MCP tool tests
- End-to-end workflow tests

### Performance Tests
- Benchmark security scanning on large codebases
- Ensure <100ms per file for complexity analysis

---

## Documentation Deliverables

1. **SECURITY_ANALYSIS.md** - Security scanning guide
2. **ENHANCED_COMPLEXITY.md** - New complexity metrics guide
3. **CODE_SMELLS.md** - Smell detection guide
4. **COHESION_ANALYSIS.md** - Cohesion metrics guide
5. **STATE_MANAGEMENT.md** - State pattern guide
6. **METASTATIC_INTEGRATION_COMPLETE.md** - Final summary

---

## Risk Mitigation

### Potential Issues

1. **Metastatic AST Structure Mismatch**
   - Risk: Our AST structure may not match what Metastatic expects
   - Mitigation: Extensive testing, adapter layers where needed

2. **Performance Impact**
   - Risk: Full analysis suite may be slow
   - Mitigation: Parallel processing, caching, optional analysis

3. **Breaking Changes**
   - Risk: New fields may break existing code
   - Mitigation: Gradual rollout, backward compatibility

---

## Success Criteria

### Phase 1 Complete When:
- [x] Security module created
- [ ] 3 MCP tools working
- [ ] Integrated with Quality
- [ ] >15 tests passing
- [ ] Documentation complete
- [ ] Zero critical vulnerabilities in Ragex itself

### All Phases Complete When:
- [ ] All 6 modules integrated
- [ ] 15+ new MCP tools
- [ ] >100 new tests
- [ ] Complete documentation suite
- [ ] Performance benchmarks met
- [ ] No regressions in existing functionality

---

## Next Steps

**Immediate** (Today):
1. Finish Phase 1 Step 1.2 (MCP tools)
2. Finish Phase 1 Step 1.3 (Quality integration)

**Tomorrow**:
1. Finish Phase 1 Step 1.4 (Tests)
2. Finish Phase 1 Step 1.5 (Documentation)
3. Start Phase 2

**This Week**:
- Complete Phases 1-2
- Start Phase 3

---

**Last Updated**: January 24, 2026  
**Current Phase**: 1 (Security Analysis)  
**Overall Progress**: 5% complete
