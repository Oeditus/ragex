# Server-Side Fixes Needed

Based on comprehensive testing with `test_all_commands.sh`, the following server issues were identified:

## Summary
- **30/40 commands work correctly** (75%)
- **9 commands have issues** - All server-side
- **1 plugin fix applied**: `suggest_refactorings` now uses `target` parameter

## Issues Breakdown

### Category A: Performance/Timeout Issues (5 commands)

These commands work but are too slow, exceeding the 15s test timeout:

#### 1. find_dead_code - PERFORMANCE
**Location**: `lib/ragex/analysis/dead_code.ex`  
**Issue**: Calls `Store.list_nodes(:function, :infinity)` then analyzes each function sequentially  
**Root Cause**: AI refinement (`AIRefiner.refine_batch`) called by default even when AI provider not available  
**Tested**: Graph has only 34 functions, so not a scale issue  
**Fix Priority**: HIGH  

**Recommended Fix**:
```elixir
# In dead_code.ex, line 654-672
defp maybe_refine_with_ai(dead_functions, ai_refine, opts) do
  use_ai =
    case ai_refine do
      true -> true
      false -> false
      nil -> AIRefiner.enabled?(opts) && ai_provider_available?()  # ADD THIS CHECK
    end
    
  # ... rest of function
end

# Add helper function
defp ai_provider_available? do
  case Ragex.AI.Registry.get_provider() do
    {:ok, _provider} -> true
    _ -> false
  end
end
```

#### 2. semantic_operations - PERFORMANCE
**Location**: `lib/ragex/analysis/semantic.ex` (Phase D)  
**Issue**: OpKind extraction via Metastatic for entire file/directory  
**Root Cause**: Metastatic parsing is CPU-intensive  
**Fix Priority**: MEDIUM  

**Recommended Fix**:
- Add file-level caching (cache OpKind results by file SHA256)
- Implement parallel processing for directories
- Add progress notifications for long operations

#### 3. semantic_analysis - PERFORMANCE
**Location**: `lib/ragex/mcp/handlers/tools.ex`  
**Issue**: Combines `semantic_operations` + `analyze_security_issues`  
**Root Cause**: Sequential execution of two slow operations  
**Fix Priority**: MEDIUM  

**Recommended Fix**:
- Run operations in parallel using `Task.async`
- Share Metastatic parsing results between operations
- Add early timeout detection

#### 4. analyze_business_logic - PERFORMANCE
**Location**: `lib/ragex/analysis/business_logic.ex`  
**Issue**: Runs 33 analyzers sequentially via Metastatic  
**Root Cause**: No parallel processing, no caching  
**Fix Priority**: MEDIUM  

**Recommended Fix**:
- Parallel analyzer execution (split into groups)
- Cache Metastatic parse results per file
- Add configurable analyzer selection (run subset)

#### 5. refactor_conflicts - HANG/INFINITE LOOP
**Location**: `lib/ragex/editor/refactor/preview.ex` or conflict detection  
**Issue**: Never returns, likely infinite loop  
**Root Cause**: TBD - needs debugging  
**Fix Priority**: HIGH  

**Recommended Fix**:
- Add timeout to conflict detection loops
- Add iteration limit guards
- Log progress for debugging
- Wrap in `Task.async` with timeout

### Category B: Internal Errors (4 commands)

These commands throw exceptions that aren't being caught properly:

#### 6. find_duplicates - PARAMETER VALIDATION
**Error**: "Internal error:" (empty message)  
**Location**: `lib/ragex/analysis/duplication.ex`  
**Issue**: Expects directory or "file1,file2" format, but error handling incomplete  
**Tested**: Single file returns error, directory may be slow but works  
**Fix Priority**: LOW  

**Recommended Fix**:
```elixir
# Better error message
cond do
  File.regular?(path) ->
    {:error, "Single file provided. For duplicates, provide a directory or two files: 'file1.ex,file2.ex'"}
  File.dir?(path) ->
    # existing directory logic
  String.contains?(path, ",") ->
    # existing two-file comparison
  true ->
    {:error, "Invalid path: #{path}"}
end
```

#### 7. suggest_refactorings - PARAMETER FORMAT
**Error**: "not a list"  
**Location**: `lib/ragex/analysis/suggestions.ex`  
**Issue**: MCP tool expects `target` as string, but internal code may expect list  
**Root Cause**: Parameter mismatch between MCP handler and internal function  
**Fix Priority**: MEDIUM  

**Recommended Fix**:
```elixir
# In suggestions.ex or MCP handler
def suggest_refactorings(target, opts) when is_binary(target) do
  # Wrap single target in list for internal processing
  suggest_refactorings([target], opts)
end

def suggest_refactorings(targets, opts) when is_list(targets) do
  # Existing logic
end
```

#### 8. metaast_search - UNIMPLEMENTED/BROKEN
**Error**: "Internal error:" (empty message)  
**Location**: `lib/ragex/rag/` or Metastatic integration  
**Issue**: MetaAST search feature may not be fully implemented  
**Fix Priority**: LOW (advanced feature)  

**Recommended Fix**:
- Add proper error handling and logging
- Return meaningful error if feature not ready: "MetaAST search not yet implemented"
- Or fix the implementation if partially complete

#### 9. cross_language_alternatives - UNIMPLEMENTED/BROKEN
**Error**: "Internal error:" (empty message)  
**Location**: `lib/ragex/rag/` cross-language feature  
**Issue**: Cross-language feature may not be fully implemented  
**Fix Priority**: LOW (advanced feature)  

**Recommended Fix**:
- Same as metaast_search
- Add explicit "not implemented" error if feature incomplete

## General Recommendations

### 1. Error Handling
Add top-level error handling to ALL MCP tool handlers:

```elixir
defp some_tool(params) do
  try do
    # existing logic
  rescue
    e ->
      Logger.error("Error in some_tool: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:error, "#{Exception.message(e)}"}
  end
end
```

### 2. Timeout Management
Add configurable timeouts to long-running operations:

```elixir
@default_metastatic_timeout 60_000  # 60s

defp analyze_with_timeout(fun, timeout \\\\ @default_metastatic_timeout) do
  task = Task.async(fun)
  
  case Task.yield(task, timeout) || Task.shutdown(task) do
    {:ok, result} -> result
    nil -> {:error, :timeout}
  end
end
```

### 3. Caching Strategy
Implement file-level caching for Metastatic results:

```elixir
defmodule Ragex.Analysis.MetastaticCache do
  def fetch(file_path, analyzer_type, fun) do
    cache_key = {file_path, file_sha256(file_path), analyzer_type}
    
    case get_cache(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> 
        result = fun.()
        put_cache(cache_key, result)
        result
    end
  end
end
```

### 4. Progress Notifications
Add progress notifications for long operations:

```elixir
defp analyze_directory_with_progress(files) do
  total = length(files)
  
  files
  |> Enum.with_index()
  |> Enum.map(fn {file, index} ->
    notify_progress(index + 1, total, file)
    analyze_file(file)
  end)
end
```

### 5. Parallel Processing
Use `Task.async_stream` for batch operations:

```elixir
def analyze_files_parallel(files, opts \\\\ []) do
  files
  |> Task.async_stream(
    fn file -> analyze_file(file, opts) end,
    max_concurrency: System.schedulers_online(),
    timeout: 60_000,
    on_timeout: :kill_task
  )
  |> Enum.map(fn
    {:ok, result} -> result
    {:exit, :timeout} -> {:error, :timeout}
  end)
end
```

## Implementation Priority

### Phase 1: Critical Fixes (Immediate)
1. Fix `find_dead_code` AI provider check
2. Fix `refactor_conflicts` infinite loop
3. Add error handling to all MCP handlers

### Phase 2: Performance (Next Sprint)
1. Add Metastatic result caching
2. Implement parallel processing for batch operations
3. Add progress notifications

### Phase 3: Feature Completion (Future)
1. Fix `suggest_refactorings` parameter handling
2. Complete/fix `metaast_search` implementation
3. Complete/fix `cross_language_alternatives` implementation

## Testing After Fixes

Run the test suite after each fix:
```bash
cd /opt/Proyectos/Oeditus/ragex/nvim-plugin
./test_all_commands.sh
```

Expected outcome:
- Phase 1: 35/40 passing (87.5%)
- Phase 2: 38/40 passing (95%)
- Phase 3: 40/40 passing (100%)

## Notes

- The plugin is functionally complete - all issues are server-side
- Core functionality (search, graph, quality, dependencies) works perfectly
- Failing commands are advanced features that need optimization or completion
- No breaking changes required - fixes are internal improvements
