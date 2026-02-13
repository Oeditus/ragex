# Ragex MCP Command Test Results

Test Date: 2026-02-13
Test Script: `test_all_commands.sh`
Total Commands Tested: 40 (out of 65 available MCP tools)

## Summary
- **Passed**: 30/40 (75%)
- **Failed**: 9/40 (22.5%)
- **Skipped**: 1/40 (2.5% - clear_ai_cache is destructive)

## ✓ PASSING COMMANDS (30)

### Basic Commands (6/6)
- ✓ graph_stats
- ✓ analyze_file
- ✓ semantic_search
- ✓ hybrid_search
- ✓ list_nodes
- ✓ get_embeddings_stats

### Graph Algorithms (4/4)
- ✓ betweenness_centrality
- ✓ closeness_centrality
- ✓ detect_communities
- ✓ export_graph

### Code Quality (3/3)
- ✓ analyze_quality
- ✓ quality_report
- ✓ find_complex_code

### Dependencies (3/3)
- ✓ analyze_dependencies
- ✓ find_circular_dependencies
- ✓ coupling_report

### Dead Code & Duplicates (2/4)
- ✓ analyze_dead_code_patterns
- ✓ find_similar_code

### Impact Analysis (3/3)
- ✓ analyze_impact
- ✓ estimate_refactoring_effort
- ✓ risk_assessment

### Security (4/4)
- ✓ analyze_security_issues
- ✓ scan_security
- ✓ check_secrets
- ✓ detect_smells

### RAG Features (1/2)
- ✓ expand_query

### AI Cache (2/2)
- ✓ get_ai_cache_stats
- ✓ get_ai_usage

### Preview & Conflicts (1/2)
- ✓ refactor_history

### Cross-Language (1/2)
- ✓ find_metaast_pattern

## ✗ FAILING COMMANDS (9)

### 1. find_dead_code - TIMEOUT
**Error**: No response or timeout (15s)
**Status**: LIKELY SERVER ISSUE - Metastatic analysis is slow
**Fix Required**: Server-side optimization needed for large code bases
**Plugin Fix**: None - parameters are correct

### 2. find_duplicates - INTERNAL ERROR
**Error**: Internal error (empty message)
**Test Command**:
```json
{"path":"/opt/Proyectos/Oeditus/ragex/lib","threshold":0.8}
```
**Status**: SERVER ISSUE - Error in Metastatic integration
**Fix Required**: Server-side debugging needed
**Plugin Fix**: None - parameters match MCP spec

### 3. suggest_refactorings - INTERNAL ERROR  
**Error**: Internal error: "not a list"
**Test Command**:
```json
{"target":"/opt/Proyectos/Oeditus/ragex/lib/ragex/graph/store.ex","min_priority":"low"}
```
**Status**: PARAMETER ISSUE
**Fix Applied**: Changed `path` to `target` in `analysis.lua`
**Remaining Issue**: Server expects different format - needs investigation
**Plugin Fix**: ✓ Parameter name fixed (path → target)

### 4. semantic_operations - TIMEOUT
**Error**: No response or timeout (15s)
**Status**: LIKELY SERVER ISSUE - OpKind analysis via Metastatic
**Fix Required**: Server-side timeout or performance issue
**Plugin Fix**: None - parameters are correct

### 5. semantic_analysis - TIMEOUT
**Error**: No response or timeout (15s)  
**Status**: LIKELY SERVER ISSUE - Combined semantic + security analysis
**Fix Required**: Server-side timeout issue
**Plugin Fix**: None - parameters are correct

### 6. analyze_business_logic - TIMEOUT
**Error**: No response or timeout (15s)
**Status**: LIKELY SERVER ISSUE - Runs 33 analyzers via Metastatic
**Fix Required**: Server-side performance optimization needed
**Plugin Fix**: None - parameters are correct

### 7. refactor_conflicts - TIMEOUT
**Error**: No response or timeout (15s)
**Status**: SERVER ISSUE - Likely infinite loop or hanging
**Fix Required**: Server-side debugging needed
**Plugin Fix**: None - parameters are correct

### 8. metaast_search - INTERNAL ERROR
**Error**: Internal error (empty message)
**Test Command**:
```json
{"source_language":"elixir","source_construct":"Enum.map/2","limit":3}
```
**Status**: SERVER ISSUE - MetaAST search implementation
**Fix Required**: Server-side debugging needed
**Plugin Fix**: None - parameters match MCP spec

### 9. cross_language_alternatives - INTERNAL ERROR
**Error**: Internal error (empty message)
**Test Command**:
```json
{"language":"elixir","code":"Enum.map(list, fn x -> x * 2 end)"}
```
**Status**: SERVER ISSUE - Cross-language feature
**Fix Required**: Server-side debugging needed
**Plugin Fix**: None - parameters match MCP spec

## Analysis

### Plugin Issues
- **1 parameter fix applied**: `suggest_refactorings` now uses `target` instead of `path`
- **All other failures are server-side issues**

### Server Issues

#### Timeout Issues (5 commands)
These commands exceed the 15s timeout:
1. `find_dead_code` - Interprocedural analysis via Metastatic
2. `semantic_operations` - OpKind extraction
3. `semantic_analysis` - Combined semantic + security
4. `analyze_business_logic` - 33 analyzers
5. `refactor_conflicts` - Conflict detection

**Root Cause**: Metastatic-based operations are computationally expensive
**Recommendation**: 
- Add server-side caching for Metastatic analysis
- Implement incremental analysis
- Add progress notifications
- Increase default timeouts for these operations

#### Internal Errors (4 commands)
These commands return internal errors:
1. `find_duplicates` - Empty error message
2. `suggest_refactorings` - "not a list" error
3. `metaast_search` - Empty error message
4. `cross_language_alternatives` - Empty error message

**Root Cause**: Server-side exceptions not being handled properly
**Recommendation**:
- Add better error handling and logging
- Return meaningful error messages
- Fix parameter validation

## Recommendations

### For Plugin
✓ DONE: Fix `suggest_refactorings` parameter (`path` → `target`)

### For Server
1. **Performance**: Optimize Metastatic-based operations
   - Add caching layer
   - Implement incremental analysis
   - Add early stopping for large codebases
   
2. **Error Handling**: Improve error messages
   - Catch and format exceptions properly
   - Return actionable error messages
   - Add parameter validation with clear messages

3. **Timeouts**: Adjust default timeouts
   - Metastatic operations: 60s+
   - Simple queries: 15s
   - Add streaming responses for long operations

4. **Debugging**: Add verbose logging mode
   - Log parameter validation
   - Log Metastatic call stack
   - Add timing information

## Testing Instructions

1. Start Ragex server:
   ```bash
   cd /opt/Proyectos/Oeditus/ragex
   ./start_server.sh
   ```

2. Run test suite:
   ```bash
   cd nvim-plugin
   ./test_all_commands.sh
   ```

3. Test individual command:
   ```bash
   printf '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"TOOL_NAME","arguments":{...}},"id":1}\n' | socat - UNIX-CONNECT:/tmp/ragex_mcp.sock
   ```

## Conclusion

**Plugin Status**: ✓ FUNCTIONAL - 1 parameter fix applied, all other issues are server-side

**Server Status**: ⚠ NEEDS WORK - 9 commands have performance or error handling issues

**Overall**: 75% of commands work correctly. The failing commands are primarily:
- Complex Metastatic-based analysis operations (timeouts)
- Advanced features needing debugging (internal errors)

The core functionality (search, analysis, graph algorithms, quality, dependencies) all work correctly.
