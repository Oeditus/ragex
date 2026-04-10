# MCP Tools, Resources, and Prompts Reference

Ragex exposes 72 MCP tools, 6 resources, and 6 prompts via the [Model Context Protocol](https://spec.modelcontextprotocol.io/) over stdio and Unix socket (`/tmp/ragex_mcp.sock`).

All tools are called via `tools/call` with JSON-RPC 2.0. Resources are read via `resources/read`. Prompts are retrieved via `prompts/get`.

## Quick Reference

```json
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"TOOL_NAME","arguments":{...}},"id":1}
```

---

## Tools

### Indexing and Analysis

#### `analyze_file`
Analyze a source file and extract code structure (modules, functions, calls) into the knowledge graph. Supports auto-detection of language from file extension.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Absolute or relative path to the file |
| `language` | string | no | auto | `elixir`, `erlang`, `python`, `javascript`, `typescript`, `auto` |
| `generate_embeddings` | boolean | no | true | Generate embeddings for semantic search |

#### `analyze_directory`
Recursively analyze all supported files in a directory, extracting code structure into the knowledge graph.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Path to the directory (or file) to analyze |
| `max_depth` | integer | no | 10 | Maximum directory depth to traverse |
| `exclude_patterns` | string[] | no | | Patterns to exclude (e.g., `node_modules`, `.git`) |

#### `watch_directory`
Start watching a directory for file changes and auto-reindex modified files.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Directory path to watch |

#### `unwatch_directory`
Stop watching a directory.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Directory path to stop watching |

#### `list_watched`
List all currently watched directories. No parameters.

---

### Knowledge Graph Queries

#### `query_graph`
Query the knowledge graph for code entities and relationships.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query_type` | string | yes | `find_module`, `find_function`, `get_calls`, `get_dependencies` |
| `params` | object | yes | Query-specific parameters |

#### `list_nodes`
List all nodes in the knowledge graph with optional filtering.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `node_type` | string | no | | Filter by node type (module, function, etc.) |
| `limit` | integer | no | 100 | Maximum results |

#### `graph_stats`
Get comprehensive graph statistics including PageRank and centrality metrics. No parameters.

Returns: `node_count`, `edge_count`, `average_degree`, `density`, `top_by_pagerank`, `top_by_degree`, `node_counts_by_type`.

#### `find_callers`
Find all functions that call a specific function.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `module` | string | yes | Module name (e.g., `MyModule`) |
| `function_name` | string | yes | Function name (e.g., `process`) |
| `arity` | integer | no | Function arity (searches any arity if omitted) |

#### `find_paths`
Find all paths (call chains) between two functions or modules.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `from` | string | yes | | Source node ID (e.g., `ModuleA.function/1`) |
| `to` | string | yes | | Target node ID (e.g., `ModuleB.function/2`) |
| `max_depth` | integer | no | 10 | Maximum path length |

---

### Search

#### `semantic_search`
Search codebase using natural language queries via embedding-based semantic similarity.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `query` | string | yes | | Natural language query (e.g., "function to parse JSON") |
| `limit` | integer | no | 10 | Maximum results |
| `threshold` | number | no | 0.2 | Minimum similarity score (0.0-1.0, typical: 0.1-0.3) |
| `node_type` | string | no | | Filter: `module` or `function` |
| `include_context` | boolean | no | true | Include related entities (callers, callees) |

#### `hybrid_search`
Advanced search combining symbolic graph queries with semantic similarity using Reciprocal Rank Fusion.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `query` | string | yes | | Natural language search query |
| `strategy` | string | no | fusion | `fusion`, `semantic_first`, `graph_first` |
| `limit` | integer | no | 10 | Maximum results |
| `threshold` | number | no | 0.15 | Minimum similarity score |
| `node_type` | string | no | | Filter: `module` or `function` |
| `include_context` | boolean | no | true | Include related entities |

#### `metaast_search`
Search for semantically equivalent code constructs across languages using MetaAST analysis.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `source_language` | string | yes | | `elixir`, `erlang`, `python`, `javascript` |
| `source_construct` | string | yes | | e.g., `Enum.map/2`, `list_comprehension`, or MetaAST pattern |
| `target_languages` | string[] | no | [] | Target languages (empty = all) |
| `limit` | integer | no | 5 | Max results per language |
| `threshold` | number | no | 0.6 | Semantic similarity threshold |
| `strict_equivalence` | boolean | no | false | Require exact AST match |

#### `cross_language_alternatives`
Suggest cross-language alternatives for a code construct.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `language` | string | yes | | Source language |
| `code` | string | yes | | Code snippet or construct description |
| `target_languages` | string[] | no | [] | Languages to generate alternatives for |

#### `expand_query`
Expand a search query with semantic synonyms and cross-language terms.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `query` | string | yes | | Original search query |
| `intent` | string | no | auto | `explain`, `refactor`, `example`, `debug`, `general` |
| `max_terms` | integer | no | 5 | Maximum expansion terms |
| `include_synonyms` | boolean | no | true | Include semantic synonyms |
| `include_cross_language` | boolean | no | true | Include cross-language terms |

#### `find_metaast_pattern`
Find all implementations of a MetaAST pattern across all languages.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `pattern` | string | yes | | MetaAST pattern (e.g., `collection_op:map`, `loop:for`, `lambda`) |
| `languages` | string[] | no | [] | Filter by languages (empty = all) |
| `limit` | integer | no | 20 | Maximum results |

---

### Graph Algorithms

#### `betweenness_centrality`
Compute betweenness centrality to identify bridge/bottleneck functions using Brandes' algorithm.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `max_nodes` | integer | no | 1000 | Limit computation to N highest-degree nodes |
| `normalize` | boolean | no | true | Return normalized scores (0-1) |

#### `closeness_centrality`
Compute closeness centrality to identify central functions in the call graph.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `normalize` | boolean | no | true | Return normalized scores (0-1) |

#### `detect_communities`
Detect communities/clusters in the call graph to identify architectural modules.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `algorithm` | string | no | louvain | `louvain` or `label_propagation` |
| `max_iterations` | integer | no | 10 | Maximum iterations |
| `resolution` | number | no | 1.0 | Resolution parameter (Louvain only) |
| `hierarchical` | boolean | no | false | Return hierarchical structure (Louvain only) |
| `seed` | integer | no | | Random seed (label propagation only) |

#### `export_graph`
Export the call graph in visualization formats.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `format` | string | yes | graphviz | `graphviz` (DOT) or `d3` (JSON) |
| `include_communities` | boolean | no | true | Include community clustering |
| `color_by` | string | no | pagerank | `pagerank`, `betweenness`, `degree` (graphviz only) |
| `max_nodes` | integer | no | 500 | Maximum nodes to include |

---

### File Editing

#### `edit_file`
Safely edit a single file with automatic backup, syntax validation, and atomic operations.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Path to the file |
| `changes` | array | yes | | List of changes (see below) |
| `validate` | boolean | no | true | Validate syntax before applying |
| `create_backup` | boolean | no | true | Create backup before editing |
| `language` | string | no | auto | Explicit language for validation |

Each change object:
- `type`: `replace`, `insert`, or `delete`
- `line_start`: Starting line number (1-indexed)
- `line_end`: Ending line (for replace/delete)
- `content`: New content (for replace/insert)

#### `edit_files`
Atomically edit multiple files with automatic rollback on failure.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `files` | array | yes | | List of `{path, changes, validate?, format?, language}` objects |
| `validate` | boolean | no | true | Validate all files before applying |
| `create_backup` | boolean | no | true | Create backups |
| `format` | boolean | no | false | Format code after editing |

#### `validate_edit`
Preview validation of changes without applying them.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Path to the file |
| `changes` | array | yes | List of changes to validate |
| `language` | string | no | Explicit language for validation |

#### `rollback_edit`
Undo a recent edit by restoring from backup.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Path to the file |
| `backup_id` | string | no | Specific backup to restore (default: most recent) |

#### `edit_history`
Query backup history for a file.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Path to the file |
| `limit` | integer | no | 10 | Maximum backups to return |

#### `read_file`
Read the contents of a source file with line numbers.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Absolute path to the file |
| `start_line` | integer | no | Start line (1-indexed) |
| `end_line` | integer | no | End line (1-indexed) |

---

### Refactoring

#### `refactor_code`
Semantic refactoring operations using AST analysis and knowledge graph.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `operation` | string | yes | | `rename_function` or `rename_module` |
| `params` | object | yes | | `{module, old_name, new_name, arity}` |
| `scope` | string | no | project | `module` or `project` |
| `validate` | boolean | no | true | Validate before and after |
| `format` | boolean | no | true | Format code after refactoring |

#### `advanced_refactor`
Advanced refactoring operations with 8 operation types.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `operation` | string | yes | | See operations below |
| `params` | object | yes | | Operation-specific parameters |
| `validate` | boolean | no | true | Validate before and after |
| `format` | boolean | no | true | Format code after refactoring |
| `scope` | string | no | project | `module` or `project` |

Operations:
- `extract_function` -- params: `{module, source_function, source_arity, new_function, line_start, line_end}`
- `inline_function` -- params: `{module, function, arity}`
- `convert_visibility` -- params: `{module, function, arity, visibility}` (visibility: `public` or `private`)
- `rename_parameter` -- params: `{module, function, arity, old_name, new_name}`
- `modify_attributes` -- params: `{module, changes}` (changes: list of `{action, attribute, value}`)
- `change_signature` -- params: `{module, function, arity, changes}` (changes: list of `{action, param_name, position, default}`)
- `move_function` -- params: `{source_module, target_module, function, arity}`
- `extract_module` -- params: `{source_module, new_module, functions}` (functions: list of `{name, arity}`)

#### `preview_refactor`
Preview refactoring changes without applying them. Shows diffs, conflicts, and statistics with optional AI commentary.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `operation` | string | yes | | `rename_function`, `rename_module`, `extract_function`, `inline_function` |
| `params` | object | yes | | Operation-specific parameters |
| `format` | string | no | unified | `unified`, `side_by_side`, `json` |
| `ai_commentary` | boolean | no | true | Generate AI risk assessment |

#### `refactor_conflicts`
Check for conflicts before applying a refactoring operation.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `operation` | string | yes | `rename_function`, `rename_module`, `move_function`, `extract_module` |
| `params` | object | yes | Operation-specific parameters |

#### `undo_refactor`
Undo the most recent refactoring operation.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `project_path` | string | no | Project root path (uses cwd if not specified) |

#### `refactor_history`
List refactoring operation history with timestamps and file counts.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `project_path` | string | no | cwd | Project root path |
| `limit` | integer | no | 50 | Maximum entries |
| `include_undone` | boolean | no | false | Include undone operations |

#### `visualize_impact`
Visualize the impact of refactoring changes.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `files` | string[] | yes | | File paths affected by refactoring |
| `format` | string | no | ascii | `graphviz`, `d3_json`, `ascii` |
| `depth` | integer | no | 1 | Impact radius depth |
| `include_risk` | boolean | no | true | Include risk analysis |

#### `suggest_refactorings`
Analyze code and generate prioritized refactoring suggestions.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `target` | string | yes | | File path, directory, or module name |
| `patterns` | string[] | no | all | Filter: `extract_function`, `inline_function`, `split_module`, `merge_modules`, `remove_dead_code`, `reduce_coupling`, `simplify_complexity`, `extract_module` |
| `min_priority` | string | no | low | `info`, `low`, `medium`, `high`, `critical` |
| `include_actions` | boolean | no | true | Include step-by-step action plans |
| `use_rag` | boolean | no | false | Use RAG for AI-powered advice |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

#### `explain_suggestion`
Get detailed explanation for a specific refactoring suggestion.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `suggestion_id` | string | yes | | ID from `suggest_refactorings` response |
| `include_code_context` | boolean | no | true | Include relevant code snippets |
| `use_rag` | boolean | no | false | Generate enhanced explanation using RAG |

#### `estimate_refactoring_effort`
Estimate effort required for a refactoring operation.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `operation` | string | yes | | `rename_function`, `rename_module`, `extract_function`, `inline_function`, `move_function`, `change_signature` |
| `target` | string | yes | | `Module.function/arity` or `Module` |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

#### `risk_assessment`
Calculate risk score for changing a function or module.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `target` | string | yes | | `Module.function/arity` or `Module` |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

---

### Code Quality and Analysis

#### `analyze_quality`
Analyze code quality metrics (complexity, purity, LOC) using Metastatic.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `metrics` | string[] | no | all | `cyclomatic`, `cognitive`, `nesting`, `halstead`, `loc`, `function_metrics`, `purity` |
| `store_results` | boolean | no | true | Store in knowledge graph |
| `recursive` | boolean | no | true | Recurse directories |

#### `quality_report`
Generate a comprehensive quality report for analyzed files.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `report_type` | string | no | summary | `summary`, `detailed`, `by_language`, `trends` |
| `format` | string | no | text | `text`, `json`, `markdown` |
| `include_files` | boolean | no | false | Include individual file details |

#### `find_complex_code`
Find files or functions exceeding complexity thresholds.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `metric` | string | no | cyclomatic | `cyclomatic`, `cognitive`, `nesting` |
| `threshold` | number | no | 10 | Threshold value |
| `comparison` | string | no | gt | `gt`, `gte`, `lt`, `lte`, `eq` |
| `limit` | integer | no | 20 | Maximum results |
| `sort_order` | string | no | desc | `asc` or `desc` |
| `show_functions` | boolean | no | false | Include per-function breakdown |

#### `detect_smells`
Detect code smells: long functions, deep nesting, magic numbers, complex conditionals, long parameter lists.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `recursive` | boolean | no | true | Recurse directories |
| `min_severity` | string | no | low | `low`, `medium`, `high`, `critical` |
| `thresholds` | object | no | | `{max_statements: 50, max_nesting: 4, max_parameters: 5, max_cognitive: 15}` |
| `smell_types` | string[] | no | all | `long_function`, `deep_nesting`, `magic_number`, `complex_conditional`, `long_parameter_list` |

#### `analyze_business_logic`
Analyze files for business logic issues using 33 analyzers (20 business logic + 13 CWE-based security).

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `analyzers` | string[] | no | all | Filter specific analyzers (see below) |
| `min_severity` | string | no | info | `info`, `low`, `medium`, `high`, `critical` |
| `recursive` | boolean | no | true | Recurse directories |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

Business logic analyzers: `callback_hell`, `missing_error_handling`, `silent_error_case`, `swallowing_exception`, `hardcoded_value`, `n_plus_one_query`, `inefficient_filter`, `unmanaged_task`, `telemetry_in_recursive_function`, `missing_telemetry_for_external_http`, `sync_over_async`, `direct_struct_update`, `missing_handle_async`, `blocking_in_plug`, `missing_telemetry_in_auth_plug`, `missing_telemetry_in_liveview_mount`, `missing_telemetry_in_oban_worker`, `missing_preload`, `inline_javascript`, `missing_throttle`.

CWE-based security analyzers: `sql_injection` (CWE-89), `xss_vulnerability` (CWE-79), `ssrf_vulnerability` (CWE-918), `path_traversal` (CWE-22), `insecure_direct_object_reference` (CWE-639), `missing_authentication` (CWE-306), `missing_authorization` (CWE-862), `incorrect_authorization` (CWE-863), `missing_csrf_protection` (CWE-352), `sensitive_data_exposure` (CWE-200), `unrestricted_file_upload` (CWE-434), `improper_input_validation` (CWE-20), `toctou` (CWE-367).

---

### Dependency and Dead Code Analysis

#### `analyze_dependencies`
Analyze module dependencies -- coupling metrics, circular dependencies, relationships.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `module` | string | no | all | Module name to analyze |
| `include_transitive` | boolean | no | false | Include transitive dependencies |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

#### `find_circular_dependencies`
Find circular dependencies in the codebase.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `scope` | string | no | module | `module` or `function` |
| `min_cycle_length` | integer | no | 2 | Minimum cycle length |
| `limit` | integer | no | 100 | Maximum cycles to return |

#### `coupling_report`
Generate coupling metrics report with afferent/efferent coupling and instability.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `format` | string | no | text | `text`, `json`, `markdown` |
| `sort_by` | string | no | instability | `name`, `instability`, `afferent`, `efferent` |
| `include_transitive` | boolean | no | false | Include transitive metrics |
| `threshold` | integer | no | 0 | Minimum total coupling (0 = show all) |

#### `find_dead_code`
Find potentially unused code (functions with no callers) with confidence scoring.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `scope` | string | no | all | `exports`, `private`, `all`, `modules` |
| `min_confidence` | number | no | 0.5 | Confidence threshold (0.0-1.0) |
| `exclude_tests` | boolean | no | true | Exclude test modules |
| `include_callbacks` | boolean | no | false | Include potential callbacks |
| `format` | string | no | summary | `summary`, `detailed`, `suggestions` |

#### `analyze_dead_code_patterns`
Analyze files for intraprocedural dead code patterns (unreachable code, constant conditionals) using AST analysis.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File path or directory |
| `min_confidence` | string | no | low | `low`, `medium`, `high` |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

#### `analyze_impact`
Analyze the impact of changing a function or module via graph traversal.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `target` | string | yes | | `Module.function/arity` or `Module` |
| `depth` | integer | no | 5 | Maximum traversal depth |
| `include_tests` | boolean | no | true | Include test files |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

---

### Duplicate Detection

#### `find_duplicates`
Find code duplicates using AST-based clone detection (Type I-IV) via Metastatic. Works across languages.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory (comma-separated for comparison) |
| `threshold` | number | no | 0.8 | Similarity threshold for Type III clones |
| `recursive` | boolean | no | true | Recurse directories |
| `format` | string | no | summary | `summary`, `detailed`, `json` |
| `exclude_patterns` | string[] | no | `[_build, deps, .git]` | Exclusion patterns |

#### `find_similar_code`
Find semantically similar code using embedding-based similarity.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `threshold` | number | no | 0.95 | Similarity threshold |
| `limit` | integer | no | 100 | Maximum pairs to return |
| `node_type` | string | no | function | `function` or `module` |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

---

### Security

#### `scan_security`
Scan for security vulnerabilities: injection, unsafe deserialization, hardcoded secrets, weak crypto.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `recursive` | boolean | no | true | Recurse directories |
| `min_severity` | string | no | low | `low`, `medium`, `high`, `critical` |
| `categories` | string[] | no | all | `injection`, `unsafe_deserialization`, `hardcoded_secret`, `weak_cryptography`, `insecure_protocol` |

#### `security_audit`
Generate comprehensive security audit report with CWE mapping and recommendations.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Directory path to audit |
| `format` | string | no | text | `json`, `markdown`, `text` |
| `min_severity` | string | no | low | `low`, `medium`, `high`, `critical` |

#### `check_secrets`
Scan for hardcoded secrets (API keys, passwords, tokens) in source code.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `recursive` | boolean | no | true | Recurse directories |

#### `analyze_security_issues`
Run all 13 CWE-based security analyzers: SQL injection, XSS, SSRF, path traversal, authentication/authorization issues, CSRF, data exposure, etc.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `min_severity` | string | no | low | `info`, `low`, `medium`, `high`, `critical` |
| `recursive` | boolean | no | true | Recurse directories |
| `categories` | string[] | no | all | `injection`, `authentication`, `authorization`, `data_exposure`, `input_validation`, `race_condition` |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

---

### Semantic Analysis

#### `semantic_operations`
Extract semantic operations (OpKind) from code -- identifies database, auth, HTTP, cache, queue, file, and external API operations with framework-specific patterns.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `domains` | string[] | no | all | `db`, `http`, `auth`, `cache`, `queue`, `file`, `external_api` |
| `recursive` | boolean | no | true | Recurse directories |
| `include_security` | boolean | no | true | Include security-relevant operations |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

#### `semantic_analysis`
Full semantic analysis combining OpKind extraction with security assessment.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | File or directory path |
| `recursive` | boolean | no | true | Recurse directories |
| `include_operations` | boolean | no | true | Include operation breakdown by domain |
| `include_security` | boolean | no | true | Include security analysis |
| `format` | string | no | summary | `summary`, `detailed`, `json` |

---

### RAG (Retrieval-Augmented Generation)

All RAG tools require an AI provider to be configured (DeepSeek, OpenAI, Anthropic, or Ollama).

#### `rag_query`
Query codebase using RAG with AI.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `query` | string | yes | | Natural language query about the codebase |
| `limit` | integer | no | 10 | Max code snippets to retrieve |
| `include_code` | boolean | no | true | Include full code snippets |
| `provider` | string | no | default | `deepseek_r1`, `openai`, `anthropic`, `ollama` |

#### `rag_explain`
Explain code using RAG with AI assistance.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `target` | string | yes | | File path or `Module.function/2` |
| `aspect` | string | no | all | `purpose`, `complexity`, `dependencies`, `all` |

#### `rag_suggest`
Suggest code improvements using RAG with AI.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `target` | string | yes | | File path or function identifier |
| `focus` | string | no | all | `performance`, `readability`, `testing`, `security`, `all` |

#### `rag_query_stream`
Same as `rag_query` but uses streaming internally. Returns complete result.

Additional parameter: `show_chunks` (boolean, default: false) -- include intermediate chunks for debugging.

#### `rag_explain_stream`
Same as `rag_explain` with internal streaming. Additional: `show_chunks`.

#### `rag_suggest_stream`
Same as `rag_suggest` with internal streaming. Additional: `show_chunks`.

#### `validate_with_ai`
Validate code with AI-enhanced error explanations and fix suggestions.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `content` | string | yes | | Code content to validate |
| `path` | string | no | | File path (for language detection) |
| `language` | string | no | auto | `elixir`, `erlang`, `python`, `javascript`, `typescript` |
| `ai_explain` | boolean | no | true | Enable AI explanations |
| `surrounding_lines` | integer | no | 3 | Context lines around errors |

---

### AI and Embeddings

#### `get_embeddings_stats`
Get statistics about indexed embeddings. No parameters.

#### `get_ai_usage`
Get AI provider usage statistics (requests, tokens, costs).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `provider` | string | no | Filter by `openai`, `anthropic`, `deepseek_r1`, `ollama` |

#### `get_ai_cache_stats`
Get AI response cache statistics and hit rates. No parameters.

#### `clear_ai_cache`
Clear AI response cache.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `operation` | string | no | `query`, `explain`, `suggest`, or `all` |

---

### Agent

The agent system provides conversational analysis sessions with persistent context.

#### `agent_analyze`
Analyze a project and generate an AI-polished report. Creates a session for follow-up conversation.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `path` | string | yes | | Project root path |
| `provider` | string | no | deepseek_r1 | AI provider |
| `include_suggestions` | boolean | no | true | Include refactoring suggestions |
| `skip_embeddings` | boolean | no | false | Skip embeddings for faster analysis |

Returns a `session_id` for use with `agent_chat`.

#### `agent_chat`
Continue conversation with the agent in an existing session.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `session_id` | string | yes | Session ID from `agent_analyze` |
| `message` | string | yes | User message or question |
| `provider` | string | no | AI provider override |

#### `agent_session_info`
Get information about an agent session.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `session_id` | string | yes | Session ID |

#### `agent_list_sessions`
List all active agent sessions.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `limit` | integer | no | 20 | Maximum sessions |

#### `agent_clear_session`
End and clear an agent session.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `session_id` | string | yes | Session ID |

---

## Resources

Resources provide read-only access to Ragex's internal state. Read via `resources/read` with the resource URI.

```json path=null start=null
{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"ragex://graph/stats"},"id":1}
```

### `ragex://graph/stats` -- Graph Statistics
Comprehensive knowledge graph statistics including node/edge counts, PageRank scores, and centrality metrics.

Returns: `node_count`, `node_counts_by_type`, `edge_count`, `average_degree`, `density`, `top_by_pagerank`, `top_by_degree`.

### `ragex://cache/status` -- Cache Status
Embedding cache statistics including hit rates, file tracking status, and disk usage.

Returns: `cache_enabled`, `cache_file`, `cache_size_bytes`, `cache_valid`, `embeddings_count`, `model_name`, `last_saved`, `tracked_files`, `changed_files`, `unchanged_files`, `stale_entities_count`.

### `ragex://model/config` -- Model Configuration
Active embedding model configuration including name, dimensions, capabilities, and readiness.

Returns: `model_name`, `dimensions`, `ready`, `memory_usage_mb`, `capabilities` (`supports_batch`, `supports_normalization`, `local_inference`), `parameters` (`max_sequence_length`, `pooling`).

### `ragex://project/index` -- Project Index
Index of all tracked files with metadata, language distribution, and LOC statistics.

Returns: `total_files`, `tracked_files` (first 100 with `path`, `content_hash`, `analyzed_at`, `size_bytes`, `language`), `language_distribution`, `recently_changed`, `changed_files_count`, `total_entities`, `entities_by_type`.

### `ragex://algorithms/catalog` -- Algorithm Catalog
Catalog of available graph algorithms with parameters, complexity, and use cases.

Includes: `pagerank`, `betweenness_centrality`, `closeness_centrality`, `degree_centrality`, `find_paths`, `detect_communities`. Each with parameters, complexity notation, and use case descriptions.

### `ragex://analysis/summary` -- Analysis Summary
Pre-computed analysis summary including key modules, architectural insights, and community structure.

Returns: `overview` (total_nodes, total_edges, average_degree, density), `key_modules` (by PageRank), `bottlenecks` (by betweenness centrality), `communities` (top 10 by size), `community_count`.

---

## Prompts

Prompts are templated high-level workflows that compose multiple tools. Retrieved via `prompts/get`.

```json path=null start=null
{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"analyze_architecture","arguments":{"path":"/path/to/project"}},"id":1}
```

### `analyze_architecture`
Comprehensive architectural analysis: community detection, centrality metrics, structural insights.

| Argument | Required | Description |
|---|---|---|
| `path` | yes | Path to analyze |
| `depth` | no | `shallow` (quick) or `deep` (detailed with betweenness centrality and communities) |

### `find_impact`
Analyze the impact and importance of a function: callers, importance scores, refactoring risk.

| Argument | Required | Description |
|---|---|---|
| `module` | yes | Module name |
| `function` | yes | Function name |
| `arity` | yes | Function arity |

### `explain_code_flow`
Explain execution flow between two functions with narrative description and code context.

| Argument | Required | Description |
|---|---|---|
| `from_function` | yes | Starting function (`Module.function/arity`) |
| `to_function` | yes | Target function (`Module.function/arity`) |
| `context_lines` | no | Context lines to show (default: 3) |

### `find_similar_code`
Find code similar to a natural language description using hybrid search.

| Argument | Required | Description |
|---|---|---|
| `description` | yes | Natural language description |
| `file_type` | no | Language filter (e.g., `elixir`, `python`) |
| `top_k` | no | Number of results (default: 5) |

### `suggest_refactoring`
Analyze code and suggest refactoring opportunities.

| Argument | Required | Description |
|---|---|---|
| `target_path` | yes | Path to analyze |
| `focus` | no | `modularity`, `coupling`, or `complexity` |

### `safe_rename`
Preview and optionally perform safe semantic renaming with impact analysis.

| Argument | Required | Description |
|---|---|---|
| `type` | yes | `function` or `module` |
| `old_name` | yes | Current name |
| `new_name` | yes | New name |
| `scope` | no | `module` or `project` (default: project) |

---

## Supported Languages

- **Elixir** (.ex, .exs) -- full support including AST-aware refactoring
- **Erlang** (.erl, .hrl) -- analysis, search, quality metrics
- **Python** (.py) -- analysis, search, quality metrics
- **JavaScript** (.js, .jsx, .mjs) -- analysis, search, quality metrics
- **TypeScript** (.ts, .tsx) -- analysis, search, quality metrics

## Connection

**stdio**: Launch with `mix run --no-halt`. Send JSON-RPC 2.0 messages to stdin, read responses from stdout. Used by MCP-compatible clients (Claude Desktop, etc.).

**Unix socket**: Connect to `/tmp/ragex_mcp.sock`. Each request is a single JSON-RPC 2.0 line terminated by `\n`. Used by editor integrations (NeoVim, LunarVim).

```bash path=null start=null
# Example: ping the socket server
(echo '{"jsonrpc":"2.0","method":"ping","id":1}'; sleep 3) | socat -T5 STDIO UNIX-CONNECT:/tmp/ragex_mcp.sock
```
