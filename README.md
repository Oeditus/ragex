# ![Ragex Logo](https://github.com/user-attachments/assets/9787c8a8-c0bf-46c0-94cb-cceda2c1ec11) Ragex

**Hybrid Retrieval-Augmented Generation for Multi-Language Codebases**

Ragex is an MCP (Model Context Protocol) server that analyzes codebases using compiler output and language-native tools to build comprehensive knowledge graphs. It enables natural language querying of code structure, relationships, and semantics.

## Features

<details>
  <summary>Foundation</summary>
    ▸ MCP Server Protocol: Full JSON-RPC 2.0 implementation over both stdio and socket<br/>
    ▸ Elixir Code Analyzer: AST-based parser extracting modules, functions, calls, and dependencies<br/>
    ▸ Knowledge Graph: ETS-based storage for code entities and relationships<br/>
    ▸ MCP Tools:<br/>
      ▹ `analyze_file`: Parse and index source files<br/>
      ▹ `query_graph`: Search for modules, functions, and relationships<br/>
      ▹ `list_nodes`: Browse indexed code entities
</details>
<details>
  <summary>Multi-Language Support</summary>
    ▸ Erlang Analyzer: Uses `:erl_scan` and `:erl_parse` for native Erlang AST parsing<br/>
    ▸ Python Analyzer: Shells out to Python's `ast` module for comprehensive analysis<br/>
    ▸ Ruby Analyzer: Uses Metastatic Ruby adapter (parser gem) with native fallback<br/>
    ▸ JavaScript/TypeScript Analyzer: Regex-based parsing for common JS/TS patterns<br/>
    ▸ Auto-detection: Automatically detects language from file extension<br/>
    ▸ Directory Analysis: Batch analyze entire projects with parallel processing<br/>
    ▸ File Watching: Auto-reindex on file changes<br/>
    ▸ Supported Extensions: `.ex`, `.exs`, `.erl`, `.hrl`, `.py`, `.rb`, `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`
</details>
<details>
  <summary>Semantic Search & Hybrid Retrieval</summary>
    ▸ Embeddings Foundation<br/>
      ▹ Local ML Model: Bumblebee integration with sentence-transformers/all-MiniLM-L6-v2<br/>
      ▹ Vector Embeddings: 384-dimensional embeddings for code entities<br/>
      ▹ Automatic Generation: Embeddings created during code analysis<br/>
      ▹ Text Descriptions: Natural language descriptions for modules and functions<br/>
      ▹ ETS Storage: Embeddings stored alongside graph entities<br/>
      ▹ No External APIs: Fully local model inference (~400MB memory)<br/><br/>
    ▸ Vector Store<br/>
      ▹ Cosine Similarity: Fast vector similarity search (less than 50ms for 100 entities)<br/>
      ▹ Parallel Search: Concurrent similarity calculations<br/>
      ▹ Filtering: By node type, similarity threshold, and result limit<br/>
      ▹ k-NN Search: Nearest neighbor queries<br/>
      ▹ Statistics API: Vector store metrics and monitoring<br/><br/>
    ▸ Semantic Search Tools<br/>
      ▹ Semantic Search: Natural language code queries (“function to parse JSON”)<br/>
      ▹ Getting Embeddings Stats: ML model and vector store statistics<br/>
      ▹ Result Enrichment: Context with callers, callees, file locations<br/>
      ▹ Flexible Filtering: By type, threshold, limit, with context inclusion<br/><br/>
    ▸ Hybrid Retrieval<br/>
      ▹ Hybrid Search: Combines symbolic and semantic approaches<br/>
      ▹ Three Strategies: Fusion (RRF), semantic-first, graph-first<br/>
      ▹ Reciprocal Rank Fusion: Intelligent ranking combination (k is 60)<br/>
      ▹ Graph Constraints: Optional symbolic filtering<br/>
      ▹ Performance: <100ms for typical queries<br/><br/>
    ▸ Enhanced Graph Queries<br/>
      ▹ PageRank: Importance scoring based on call relationships<br/>
      ▹ Path Finding: Discover call chains between functions (with limits)<br/>
      ▹ Degree Centrality: In-degree, out-degree, and total degree metrics<br/>
      ▹ Graph Statistics: Comprehensive codebase analysis<br/>
      ▹ MCP Tools: `find_paths` and `graph_stats` tools
</details>
<details>
  <summary>Production Features</summary>
    ▸ Custom Embedding Models<br/>
      ▹ Model Registry: 4 pre-configured embedding models<br/>
      ▹ Flexible Configuration: Config file, environment variable, or default<br/>
      ▹ Model Compatibility: Automatic detection of compatible models (same dimensions)<br/>
      ▹ Migration Tool: `mix ragex.embeddings.migrate` for model changes<br/>
      ▹ Validation: Startup checks for model compatibility<br/><br/>
    ▸ Embedding Persistence<br/>
      ▹ Automatic Cache: Save on shutdown, load on startup<br/>
      ▹ Model Validation: Ensures cache matches current model<br/>
      ▹ Project-Specific: Isolated caches per project directory<br/>
      ▹ Cache Management: Mix tasks for stats and cleanup (`mix ragex.cache.*`)<br/>
      ▹ Performance: Cold start <5s vs 50s without cache<br/>
      ▹ Storage: ~15MB per 1,000 entities (ETS binary format)<br/><br/>
    ▸ Incremental Embedding Updates<br/>
      ▹ File Tracking: SHA256 content hashing for change detection<br/>
      ▹ Smart Diff: Only re-analyzes changed files<br/>
      ▹ Selective Regeneration: Updates embeddings for modified entities only<br/>
      ▹ Performance: <5% regeneration on single-file changes<br/>
      ▹ Mix Task: `mix ragex.cache.refresh` for incremental/full updates<br/><br/>
    ▸ Path Finding Limits<br/>
      ▹ `max_paths` Parametrization: Limits returned paths (default: 100) to prevent hangs<br/>
      ▹ Early Stopping: DFS traversal stops when max_paths reached<br/>
      ▹ Dense Graph Detection: Automatic warnings for highly-connected nodes (≥10 edges)<br/>
      ▹ Configurable Options: max_depth, max_paths, warn_dense flags<br/>
      ▹ Performance: Prevents exponential explosion on dense graphs
</details>
<details>
  <summary>Code Editing Capabilities</summary>
    ▸ Core Editor Infrastructure<br/>
      ▹ Editor Types: Change types (replace, insert, delete) with validation<br/>
      ▹ Backup Management: Automatic backups with timestamps and project-specific directories<br/>
      ▹ Core Editor: Atomic operations with concurrent modification detection<br/>
      ▹ Rollback Support: Restore previous versions from backup history<br/>
      ▹ Configuration: Backup retention, compression, and directory settings<br/><br/>
    ▸ Validation Pipeline<br/>
      ▹ Validator Behavior: Behavior definition with callbacks and orchestration<br/>
      ▹ Elixir Validator: Syntax validation using `Code.string_to_quoted/2`<br/>
      ▹ Erlang Validator: Validation using `:erl_scan` and `:erl_parse`<br/>
      ▹ Python Validator: Shell-out to Python's `ast.parse()` for syntax checking<br/>
      ▹ Ruby Validator: `ruby -c` for Ruby syntax checking<br/>
      ▹ JavaScript Validator: Node.js `vm.Script` for JS/TS validation<br/>
      ▹ Automatic Detection: Language detection from file extension<br/>
      ▹ Core Integration: Validators integrated with `Core.edit_file`<br/><br/>
    ▸ MCP Edit Tools<br/>
      ▹ edit_file: MCP tool for safe file editing with validation<br/>
      ▹ validate_edit: Preview validation before applying changes<br/>
      ▹ rollback_edit: Undo recent edits via MCP<br/>
      ▹ edit_history: Query backup history<br/><br/>
    ▸ Advanced Editing<br/>
      ▹ Format Integration: Auto-format after edits with language-specific formatters<br/>
      ▹ Formatter Detection: Automatic formatter discovery (mix, rebar3, black, rubocop, prettier)<br/>
      ▹ Core Integration: `:format` option in `Core.edit_file`<br/>
      ▹ Multi-file Transactions: Atomic cross-file changes with automatic rollback<br/>
      ▹ Transaction Validation: Pre-validate all files before applying changes<br/>
      ▹ MCP Integration: `edit_files` tool for coordinated multi-file edits<br/><br/>
    ▸ Semantic Refactoring<br/>
      ▹ AST Manipulation: Elixir-specific AST parsing and transformation<br/>
      ▹ Rename Function: Rename functions with automatic call site updates<br/>
      ▹ Rename Module: Rename modules with reference updates<br/>
      ▹ Graph Integration: Use knowledge graph to find all affected files<br/>
      ▹ Arity Support: Handle functions with multiple arities correctly<br/>
      ▹ Scope Control: Module-level or project-wide refactoring<br/>
      ▹ MCP Integration: `refactor_code` tool for semantic refactoring<br/><br/>
    ▸ Advanced Refactoring<br/>
      ▹ Extract Function: Extract code range into new function (basic support)<br/>
      ▹ Inline Function: Replace all calls with function body, remove definition (fully working)<br/>
      ▹ Convert Visibility: Toggle between `def` and `defp` (fully working)<br/>
      ▹ Rename Parameter: Rename parameter within function scope (fully working)<br/>
      ▹ Modify Attributes: Add/remove/update module attributes (fully working)<br/>
      ▹ Change Signature: Add/remove/reorder/rename parameters with call site updates (fully working)<br/>
      ▹ Move Function: Move function between modules (deferred - requires advanced semantic analysis)<br/>
      ▹ Extract Module: Extract multiple functions into new module (deferred - requires advanced semantic analysis)<br/>
      ▹ MCP Integration: `advanced_refactor` tool with 8 operation types<br/>
      ▹ Status: 6 of 8 operations fully functional, 2 deferred pending semantic analysis enhancements
</details>
<details>
  <summary>Advanced Graph Algorithms</summary>
    ▸ Centrality Metrics<br/>
      ▹ Betweenness Centrality: Identify bridge/bottleneck functions using Brandes’ algorithm<br/>
      ▹ Closeness Centrality: Identify central functions based on average distance<br/>
      ▹ Normalized Scores: Configurable 0-1 normalization<br/>
      ▹ Performance Limits: `max_nodes` parameter for large graphs<br/>
      ▹ MCP Tools: `betweenness_centrality` and `closeness_centrality`<br/><br/>
    ▸ Community Detection<br/>
      ▹ Louvain Method: Modularity optimization for discovering architectural modules<br/>
      ▹ Label Propagation: Fast alternative algorithm (O(m) per iteration)<br/>
      ▹ Hierarchical Structure: Multi-level community detection support<br/>
      ▹ Weighted Edges: Support for edge weights (call frequency)<br/>
      ▹ MCP Tool: `detect_communities` with algorithm selection<br/><br/>
    ▸ Weighted Graph Support<br/>
      ▹ Edge Weights: Store call frequency in edge metadata (default: 1.0)<br/>
      ▹ Weighted Algorithms: Modularity computation with weights<br/>
      ▹ Store Integration: `get_edge_weight` helper function<br/><br/>
    ▸ Graph Visualization<br/>
      ▹ Graphviz DOT Export: Community clustering, colored nodes, weighted edges<br/>
      ▹ D3.js JSON Export: Force-directed graph format with metadata<br/>
      ▹ Node Coloring: By PageRank, betweenness, or degree centrality<br/>
      ▹ Edge Thickness: Proportional to edge weight<br/>
      ▹ MCP Tool: `export_graph` with format selection
</details>
<details>
  <summary>MCP Resources & Prompts</summary>
    ▸ Resources (Read-only State Access)<br/>
      ▹ Graph Statistics: Node/edge counts, PageRank scores, centrality metrics<br/>
      ▹ Cache Status: Embedding cache health, file tracking, stale entities<br/>
      ▹ Model Configuration: Active model details, capabilities, readiness<br/>
      ▹ Project Index: Tracked files, language distribution, entity counts<br/>
      ▹ Algorithm Catalog: Available algorithms with parameters and complexity<br/>
      ▹ Analysis Summary: Pre-computed architectural insights and communities<br/>
      ▹ URI Format: `ragex://<category>/<resource>`<br/>
      ▹ Documentation: See [RESOURCES.md](RESOURCES.md)<br/><br/>
    ▸ Prompts (High-level Workflows)<br/>
      ▹ Analyze Architecture: Comprehensive architectural analysis (shallow/deep)<br/>
      ▹ Find Impact: Function importance and refactoring risk assessment<br/>
      ▹ Explain Code Flow: Narrative execution flow between functions<br/>
      ▹ Find Similar Code: Hybrid search with natural language descriptions<br/>
      ▹ Suggest Refactoring: Modularity, coupling, and complexity analysis<br/>
      ▹ Safe Rename: Impact preview for semantic refactoring operations<br/>
      ▹ Tool Composition: Each prompt suggests sequence of tools to use<br/>
      ▹ Documentation: See [PROMPTS.md](PROMPTS.md)
</details>
<details>
  <summary>RAG System (🔥)</summary>
    ▸ AI Provider Abstraction<br/>
      ▹ Provider Behaviour: Clean interface for multiple AI providers<br/>
      ▹ DeepSeek R1: Full integration with deepseek-chat and deepseek-reasoner models<br/>
      ▹ Streaming Support: All providers support streaming responses (SSE/NDJSON)<br/>
      ▹ Real-time Responses: Progressive content delivery with token usage tracking<br/>
      ▹ OpenAI: GPT-4, GPT-4-turbo, GPT-3.5-turbo support<br/>
      ▹ Anthropic: Claude 3 Opus, Sonnet, and Haiku models<br/>
      ▹ Ollama: Local LLM support (llama2, mistral, codellama, phi)<br/>
      ▹ Configuration System: Multi-provider with fallback support<br/>
      ▹ Provider Registry: GenServer for runtime provider management<br/><br/>
    ▸ AI Response Caching<br/>
      ▹ ETS-based Cache: SHA256 key generation with TTL expiration<br/>
      ▹ LRU Eviction: Automatic eviction when max size reached<br/>
      ▹ Operation-specific TTL: Configurable per operation type<br/>
      ▹ Cache Statistics: Hit rate, misses, puts, evictions tracking<br/>
      ▹ Mix Tasks: `mix ragex.ai.cache.stats` and `mix ragex.ai.cache.clear`<br/>
      ▹ Performance: >50% cache hit rate for repeated queries<br/><br/>
    ▸ Usage Tracking & Rate Limiting<br/>
      ▹ Per-provider Tracking: Requests, tokens, and cost estimation<br/>
      ▹ Real-time Costs: Accurate pricing for OpenAI, Anthropic, DeepSeek<br/>
      ▹ Time-windowed Limits: Per-minute, per-hour, per-day controls<br/>
      ▹ Automatic Enforcement: Rate limit checks before API calls<br/>
      ▹ Mix Tasks: `mix ragex.ai.usage.stats` for monitoring<br/>
      ▹ MCP Tools: `get_ai_usage`, `get_ai_cache_stats`<br/><br/>
    ▸ Metastatic Integration<br/>
      ▹ MetaAST Analyzer: Enhanced cross-language analysis via Metastatic library<br/>
      ▹ Supported Languages: Elixir, Erlang, Python, Ruby, Haskell<br/>
      ▹ Fallback Strategy: Graceful degradation to native analyzers<br/>
      ▹ Feature Flags: Configurable `use_metastatic` option<br/><br/>
    ▸ RAG Pipeline<br/>
      ▹ Context Builder: Format retrieval results for AI consumption (8000 char max)<br/>
      ▹ Prompt Templates: Query, explain, and suggest operations<br/>
      ▹ Full Pipeline: Retrieval → Context → Prompting → Generation → Post-processing<br/>
      ▹ Hybrid Retrieval: Leverages semantic + graph-based search<br/>
      ▹ Cache Integration: Automatic caching of AI responses<br/>
      ▹ Usage Tracking: All requests tracked with cost estimation<br/><br/>
    ▸ Agent-Based RAG (chat & audit)<br/>
      ▹ The AI drives retrieval: agent calls Ragex MCP tools directly instead of receiving pre-fetched context<br/>
      ▹ `mix ragex.chat`: every question answered via ReAct loop with `hybrid_search`, `semantic_search`, `read_file`, `query_graph`, etc.<br/>
      ▹ `mix ragex.audit`: AI report enriched by read-only RAG tool calls for concrete evidence (`ToolSchema.rag_query_tools/1`)<br/>
      ▹ Evidence-based findings: AI can quote actual function bodies, confirm dependency paths, and check coupling metrics<br/>
      ▹ Safe scoping: heavy re-analysis tools excluded so the analysis pipeline is never re-triggered during report writing<br/><br/>
    ▸ MCP RAG Tools<br/>
      ▹ `rag_query`: Answer general codebase questions with AI<br/>
      ▹ `rag_explain`: Explain code with aspect focus (purpose, complexity, dependencies, all)<br/>
      ▹ `rag_suggest`: Suggest improvements (performance, readability, testing, security, all)<br/>
      ▹ `rag_query_stream`: Streaming version of rag_query (internally uses streaming)<br/>
      ▹ `rag_explain_stream`: Streaming version of rag_explain (internally uses streaming)<br/>
      ▹ `rag_suggest_stream`: Streaming version of rag_suggest (internally uses streaming)<br/>
      ▹ `get_ai_usage`: Query usage statistics and costs per provider<br/>
      ▹ `get_ai_cache_stats`: View cache performance metrics<br/>
      ▹ `clear_ai_cache`: Clear cache via MCP<br/>
      ▹ Provider Override: Select provider per-query (openai, anthropic, deepseek_r1, ollama)<br/><br/>
    ▸ MetaAST-Enhanced Retrieval<br/>
      ▹ Context-Aware Ranking: Query intent detection (explain, refactor, example, debug)<br/>
      ▹ Purity Analysis: Boost pure functions, penalize side effects<br/>
      ▹ Complexity Scoring: Favor simple code for explanations, complex code for refactoring<br/>
      ▹ Cross-Language Search: Find equivalent constructs across languages via MetaAST<br/>
      ▹ Query Expansion: Automatic synonym injection and cross-language terms<br/>
      ▹ Pattern Search: Find all implementations of MetaAST patterns (map, filter, lambda, etc.)<br/>
      ▹ Hybrid Integration: MetaAST ranking applied to all search strategies<br/>
      ▹ MCP Tools: `metaast_search`, `cross_language_alternatives`, `expand_query`, `find_metaast_pattern`
</details>
<details>
  <summary>AI Features (🔥)</summary>
    ▸ Foundation Layer<br/>
      ▹ Features.Config: Per-feature flags with master switch<br/>
      ▹ Features.Context: Rich context builders (6 context types)<br/>
      ▹ Features.Cache: Automatic caching with TTL policies (3-7 days)<br/>
      ▹ Graceful degradation when AI disabled<br/><br/>
    ▸ High-Priority Features<br/>
      ▹ ValidationAI: AI-enhanced validation error explanations<br/>
      ▹ AIPreview: Refactoring preview with risk assessment and recommendations<br/><br/>
    ▸ Analysis Features<br/>
      ▹ AIRefiner: Dead code false positive reduction (50%+ target)<br/>
      ▹ AIAnalyzer: Semantic Type IV clone detection (>70% accuracy target)<br/>
      ▹ AIInsights: Architectural insights for coupling and circular dependencies<br/>
      ▹ Context-aware recommendations with technical debt scoring<br/><br/>
    ▸ Configuration<br/>
      ▹ Opt-in via `:ai_features` config (dead_code_refinement, duplication_semantic_analysis, etc.)<br/>
      ▹ Master switch with per-feature overrides<br/>
      ▹ Integrates with existing analysis modules (DeadCode, Duplication, DependencyGraph)<br/>
      ▹ MCP tools: validate_with_ai, enhanced preview_refactor
</details>
<details>
  <summary>Code Analysis & Quality</summary>
    ▸ Dead Code Detection<br/>
      ▹ Graph-Based Analysis: Find unused functions via call graph traversal<br/>
      ▹ Confidence Scoring: 0.0-1.0 score to distinguish callbacks from dead code<br/>
      ▹ Pattern Detection: AST-based unreachable code detection via Metastatic<br/>
      ▹ Intraprocedural Analysis: Constant conditionals, unreachable branches<br/>
      ▹ Interprocedural Analysis: Unused exports, private functions<br/>
      ▹ Callback Recognition: GenServer, Phoenix, and other framework callbacks<br/>
      ▹ MCP Tools: `find_dead_code`, `analyze_dead_code_patterns`<br/><br/>
    ▸ Dependency Analysis<br/>
      ▹ Coupling Metrics: Afferent (Ca) and Efferent (Ce) coupling<br/>
      ▹ Instability: I = Ce / (Ca + Ce) ranges from 0 (stable) to 1 (unstable)<br/>
      ▹ Circular Dependencies: Detect cycles at module and function levels<br/>
      ▹ Transitive Dependencies: Optional deep dependency traversal<br/>
      ▹ God Module Detection: Find modules with high coupling<br/>
      ▹ MCP Tools: `analyze_dependencies`, `find_circular_dependencies`, `coupling_report`<br/><br/>
    ▸ Code Duplication Detection<br/>
      ▹ AST-Based Clones: Type I-IV clone detection via Metastatic<br/>
      ▹ Type I: Exact clones (whitespace/comment differences only)<br/>
      ▹ Type II: Renamed clones (same structure, different identifiers)<br/>
      ▹ Type III: Near-miss clones (similar with modifications, configurable threshold)<br/>
      ▹ Type IV: Semantic clones (different syntax, same behavior)<br/>
      ▹ Embedding-Based Similarity: Semantic code similarity using ML embeddings<br/>
      ▹ Directory Scanning: Recursive multi-file analysis with exclusion patterns<br/>
      ▹ Reports: Summary, detailed, and JSON formats<br/>
      ▹ MCP Tools: `find_duplicates`, `find_similar_code`<br/><br/>
    ▸ Impact Analysis<br/>
      ▹ Change Impact: Predict affected code via graph traversal<br/>
      ▹ Risk Scoring: Combine importance (PageRank) + coupling + complexity<br/>
      ▹ Test Discovery: Find affected tests automatically<br/>
      ▹ Effort Estimation: Estimate refactoring time/complexity for 6 operations<br/>
      ▹ Risk Levels: Low (<0.3), medium (0.3-0.6), high (0.6-0.8), critical (≥0.8)<br/>
      ▹ Complexity Levels: Low (<5 changes), medium (5-20), high (20-50), very high (50+)<br/>
      ▹ Support Operations: rename_function, rename_module, extract_function, inline_function, move_function, change_signature<br/>
      ▹ MCP Tools: `analyze_impact`, `estimate_refactoring_effort`, `risk_assessment`<br/><br/>
    ▸ Code Smells Detection (Metastatic Integration)<br/>
      ▹ Long Function: Functions with too many statements (default: >50)<br/>
      ▹ Deep Nesting: Excessive nesting depth (default: >4 levels)<br/>
      ▹ Magic Numbers: Unexplained numeric literals in expressions<br/>
      ▹ Complex Conditionals: Deeply nested boolean operations<br/>
      ▹ Long Parameter List: Too many parameters (default: >5)<br/>
      ▹ Configurable Thresholds: Custom limits per project<br/>
      ▹ Severity Levels: Critical, high, medium, low<br/>
      ▹ Actionable Suggestions: Refactoring recommendations for each smell<br/>
      ▹ Directory Scanning: Recursive analysis with parallel processing<br/>
      ▹ Filtering: By severity or smell type<br/>
      ▹ MCP Tool: `detect_smells`<br/><br/>
    ▸ Business Logic Analysis (20 Metastatic Analyzers)<br/>
      ▹ Control Flow Issues:<br/>
        • Callback Hell: Excessive nested callbacks (default: >3 levels)<br/>
        • Missing Error Handling: Functions without try/rescue or error tuples<br/>
        • Silent Error Case: Pattern matches that ignore error tuples<br/>
        • Swallowing Exception: Rescue clauses without re-raising or logging<br/><br/>
      ▹ Data & Configuration:<br/>
        • Hardcoded Value: URLs, secrets, or config values in code<br/>
        • Direct Struct Update: Using `%{struct | ...}` instead of changesets/contexts<br/>
        • Missing Preload: Ecto queries without required preloads<br/><br/>
      ▹ Performance & Scalability:<br/>
        • N+1 Query: Multiple database queries in iterations<br/>
        • Inefficient Filter: Filtering after fetching instead of in query<br/>
        • Unmanaged Task: `Task.start` without supervision<br/>
        • Blocking in Plug: Slow synchronous operations in plug pipeline<br/>
        • Sync Over Async: Using sync calls when async is available<br/><br/>
      ▹ Observability:<br/>
        • Missing Telemetry for External HTTP: External API calls without telemetry<br/>
        • Missing Telemetry in Auth Plug: Auth operations without metrics<br/>
        • Missing Telemetry in LiveView Mount: LiveView lifecycle without tracking<br/>
        • Missing Telemetry in Oban Worker: Background jobs without observability<br/>
        • Telemetry in Recursive Function: Performance overhead from recursive telemetry<br/><br/>
      ▹ Framework-Specific:<br/>
        • Missing Handle Async: LiveView async results without handlers<br/>
        • Inline JavaScript: JavaScript in Phoenix templates/LiveView<br/>
        • Missing Throttle: User-facing actions without rate limiting<br/><br/>
      ▹ Tier Classification: 4 tiers from pure MetaAST to content analysis<br/>
      ▹ Actionable Recommendations: Specific fixes for each issue type<br/>
      ▹ Severity Levels: Critical, high, medium, low, info<br/>
      ▹ Directory Scanning: Recursive analysis with file type detection<br/>
      ▹ Filtering: By analyzer, minimum severity, or file patterns<br/>
      ▹ Reports: Summary with counts by analyzer and severity<br/>
      ▹ MCP Tool: `analyze_business_logic`<br/>
      ▹ Mix Task: `mix ragex.analyze --business-logic`<br/><br/>
    ▸ Quality Metrics (Metastatic Integration)<br/>
      ▹ Complexity Metrics (Full Suite):<br/>
        • Cyclomatic Complexity: McCabe metric (decision points + 1)<br/>
        • Cognitive Complexity: Structural complexity with nesting penalties<br/>
        • Nesting Depth: Maximum nesting level tracking<br/><br/>
      ▹ Halstead Metrics (Comprehensive):<br/>
        • Vocabulary: distinct_operators + distinct_operands<br/>
        • Length: total_operators + total_operands<br/>
        • Volume: length × log₂(vocabulary)<br/>
        • Difficulty: (distinct_operators / 2) × (total_operands / distinct_operands)<br/>
        • Effort: volume × difficulty<br/><br/>
      ▹ Lines of Code (Detailed):<br/>
        • Physical Lines: Total lines including blank/comments<br/>
        • Logical Lines: Executable statements only<br/>
        • Comments: Comment lines count<br/>
        • Blank Lines: Whitespace-only lines<br/><br/>
      ▹ Function Metrics:<br/>
        • Statement Count: Number of executable statements<br/>
        • Return Points: Multiple return analysis<br/>
        • Variable Count: Local variable tracking<br/>
        • Parameter Count: Function signature complexity<br/>
      ▹ Purity Analysis: Function purity and side-effect detection<br/>
      ▹ Per-Function Analysis: Individual function breakdown with all metrics<br/>
      ▹ Project-wide Reports: Aggregated statistics by language<br/>
      ▹ MCP Tools: `analyze_quality`, `quality_report`, `find_complex_code`<br/><br/>
    ▸ Documentation<br/>
      ▹ Comprehensive Guide: See [ANALYSIS](stuff/docs/ANALYSIS.md) for complete API documentation<br/>
      ▹ Analysis Approaches: AST-based vs embedding-based strategies<br/>
      ▹ Usage Examples: API and MCP tool examples with code snippets<br/>
      ▹ Best Practices: Threshold recommendations, workflow tips<br/>
      ▹ Troubleshooting: Common issues and solutions<br/>
      ▹ CI/CD Integration: Pre-commit hooks, pipeline examples
</details>
<details>
  <summary>CLI Improvements</summary>
    ▸ CLI Foundation<br/>
      ▹ Colors: ANSI color helpers with NO_COLOR support<br/>
      ▹ Output: Rich formatting (sections, lists, tables, key-value pairs, diffs)<br/>
      ▹ Progress: Spinners and progress indicators<br/>
      ▹ Prompt: Interactive prompts (confirm, select, input, number with validation)<br/><br/>
    ▸ Enhanced Mix Tasks (7 upgraded)<br/>
      ▹ `mix ragex.cache.{stats,refresh,clear}` - Colored output, spinners, confirmations<br/>
      ▹ `mix ragex.embeddings.migrate` - Sections, formatted output, interactive confirmations<br/>
      ▹ `mix ragex.ai.{usage.stats,cache.stats,cache.clear}` - Rich formatting, color-coded metrics<br/><br/>
    ▸ Interactive Wizards<br/>
      ▹ `mix ragex.chat` - AI-powered codebase Q&A via Ragex MCP tools:<br/>
        • Agent ReAct loop — AI calls `hybrid_search`, `semantic_search`, `read_file`, `query_graph`, etc.<br/>
        • Initial analysis + streaming audit report on first run<br/>
        • Multi-turn conversation with session memory<br/>
        • `--provider` / `--model` overrides; `--skip-analysis` to reuse existing graph<br/>
        • `--debug` to print tool-call traces to stderr<br/><br/>
      ▹ `mix ragex.audit` - AI-powered code audit report:<br/>
        • Static analysis + AI report with optional RAG evidence retrieval<br/>
        • JSON (default) or Markdown output; `--output FILE` to save<br/>
        • `--format markdown` renders the report directly in the terminal<br/>
        • `--verbose` shows progress; `--dead-code` enables dead-code section<br/><br/>
      ▹ `mix ragex.refactor` - Interactive refactoring wizard:<br/>
        • 5 operations: rename_function, rename_module, change_signature, extract_function, inline_function<br/>
        • Parameter gathering with validation<br/>
        • Knowledge graph integration<br/>
        • Preview and confirmation before applying<br/>
        • Both interactive and direct CLI modes<br/><br/>
      ▹ `mix ragex.configure` - Configuration wizard:<br/>
        • Smart project type detection<br/>
        • Embedding model comparison and selection<br/>
        • AI provider configuration with environment detection<br/>
        • Analysis options and cache settings<br/>
        • Generates complete `.ragex.exs` configuration file<br/><br/>
    ▸ Live Dashboard<br/>
      ▹ `mix ragex.dashboard` - Real-time monitoring:<br/>
        • 4 stat panels: Graph, Embeddings, Cache, AI Usage<br/>
        • Live updating display (customizable refresh interval)<br/>
        • Color-coded metrics with thresholds<br/>
        • Activity log<br/><br/>
    ▸ Shell Completions<br/>
      ▹ Bash, Zsh, Fish completion scripts<br/>
      ▹ `mix ragex.completions` - Auto-detect and install completions<br/>
      ▹ Task name completion with descriptions<br/>
      ▹ Context-aware argument completion<br/><br/>
    ▸ Documentation<br/>
      ▹ Man pages in groff format (ragex.1)<br/>
      ▹ `mix ragex.install_man` - System-wide man page installation<br/>
      ▹ Complete command reference (10 Mix tasks)<br/>
      ▹ Configuration guide and usage examples
</details>

### Planned Features

- [✓] Streaming RAG responses
- [✓] MCP streaming notifications
- [✓] MetaAST-enhanced retrieval
- [✓] Code quality analysis
- [✓] Impact analysis and risk assessment
- [✓] CLI improvements (interactive wizards, dashboard, completions, man pages)
- [✗] CI tasks
- [✗] Provider health checks and auto-failover
- [✗] Production optimizations
- [✗] Additional language support
- [✗] Cross-language refactoring via Metastatic
- [✗] Enhanced editor integrations

## Architecture

```mermaid
graph TD
    MCP["MCP Server (stdio)<br/>28 Tools + 6 Resources + 6 Prompts"]
    
    MCP --> Tools["Tools Handler"]
    MCP --> Resources["Resources Handler"]
    MCP --> Prompts["Prompts Handler"]
    MCP --> Analyzers["Analyzers<br/>(Elixir, Erlang, Metastatic)"]
    MCP --> Graph["Graph Store<br/>(ETS Knowledge Graph)"]
    MCP --> Vector["Vector Store<br/>(Cosine Similarity)"]
    MCP --> Bumblebee["Bumblebee Embedding<br/>(all-MiniLM-L6-v2)"]
    
    Tools <--> Analyzers
    Analyzers <--> Graph
    Resources --> Graph
    Resources --> Vector
    Resources --> Bumblebee
    Prompts --> Tools
    
    Tools --> Hybrid["Hybrid Retrieval (RRF)<br/>Semantic + Graph + Fusion"]
    Graph --> Hybrid
    Vector --> Hybrid
    
    Tools --> RAG["RAG Pipeline<br/>Cache → Context → Prompts → AI"]
    Hybrid --> RAG
    RAG --> Cache["AI Cache<br/>(TTL + LRU)"]
    RAG --> Usage["Usage Tracker<br/>(Costs + Limits)"]
    RAG --> AIProvider["AI Providers<br/>(OpenAI, Anthropic, DeepSeek, Ollama)"]
    
    style MCP fill:#e1f5ff,color:#01579b,stroke:#01579b,stroke-width:2px
    style Hybrid fill:#f3e5f5,color:#4a148c,stroke:#4a148c,stroke-width:2px
    style Graph fill:#e8f5e9,color:#1b5e20,stroke:#1b5e20,stroke-width:2px
    style Vector fill:#fff3e0,color:#e65100,stroke:#e65100,stroke-width:2px
    style Bumblebee fill:#fce4ec,color:#880e4f,stroke:#880e4f,stroke-width:2px
    style Resources fill:#e0f2f1,color:#004d40,stroke:#004d40,stroke-width:2px
    style Prompts fill:#fff9c4,color:#f57f17,stroke:#f57f17,stroke-width:2px
    style RAG fill:#ffebee,color:#b71c1c,stroke:#b71c1c,stroke-width:2px
    style AIProvider fill:#e8eaf6,color:#1a237e,stroke:#1a237e,stroke-width:2px
    style Cache fill:#e0f7fa,color:#006064,stroke:#006064,stroke-width:2px
    style Usage fill:#fff8e1,color:#f57c00,stroke:#f57c00,stroke-width:2px
```

## Use as MCP Server

The only MCP client currently supported is `LunarVim` (technically, any `NeoVim`,
but I never tested it.)

To enable `Ragex` support in `LunarVim`, copy files from `lvim.cfg/lua/user/` to
where your `LunarVim` configs are (typically, it’s `~/.config/lvim/lua/user/`) and
amend your `config.lua` as shown below.

```lua
-- Ragex integration
local ragex = require("user.ragex")
local ragex_telescope = require("user.ragex_telescope")

-- Setup Ragex with configuration
ragex.setup({
  ragex_path = vim.fn.expand("~/Proyectos/Ammotion/ragex"),
  enabled = true,
  debug = false,
})

-- Ragex keybindings (using "r" prefix for Ragex)
lvim.builtin.which_key.mappings["r"] = {
  name = "Ragex",
  s = { function() ragex_telescope.ragex_search() end, "Semantic Search" },
  w = { function() ragex_telescope.ragex_search_word() end, "Search Word" },
  f = { function() ragex_telescope.ragex_functions() end, "Find Functions" },
  m = { function() ragex_telescope.ragex_modules() end, "Find Modules" },
  a = { function() ragex.analyze_current_file() end, "Analyze File" },
  d = { function() ragex.analyze_directory(vim.fn.getcwd()) end, "Analyze Directory" },
  c = { function() ragex.show_callers() end, "Find Callers" },
  r = {
    function()
      vim.ui.input({ prompt = "New name: " }, function(name)
        if name then
          ragex.rename_function(name)
        end
      end)
    end,
    "Rename Function",
  },
  R = {
    function()
      vim.ui.input({ prompt = "Old module: " }, function(old_name)
        if old_name then
          vim.ui.input({ prompt = "New module: " }, function(new_name)
            if new_name then
              ragex.rename_module(old_name, new_name)
            end
          end)
        end
      end)
    end,
    "Rename Module",
  },
  g = { 
    function()
      local result = ragex.graph_stats()
      if result and result.result then
        -- Unwrap MCP response
        local stats = result.result
        if stats.content and stats.content[1] and stats.content[1].text then
          local ok, parsed = pcall(vim.fn.json_decode, stats.content[1].text)
          if ok then
            stats = parsed
          end
        end
        
        -- Format stats for display
        local lines = {
          "# Graph Statistics",
          "",
          string.format("**Nodes**: %d", stats.node_count or 0),
          string.format("**Edges**: %d", stats.edge_count or 0),
          string.format("**Average Degree**: %.2f", stats.average_degree or 0),
          string.format("**Density**: %.4f", stats.density or 0),
          "",
          "## Node Types",
        }
        
        if stats.node_counts_by_type then
          for node_type, count in pairs(stats.node_counts_by_type) do
            table.insert(lines, string.format("- %s: %d", node_type, count))
          end
        end
        
        if stats.top_by_degree and #stats.top_by_degree > 0 then
          table.insert(lines, "")
          table.insert(lines, "## Top by Degree")
          for i, node in ipairs(stats.top_by_degree) do
            if i > 10 then break end
            table.insert(lines, string.format("- %s (in:%d, out:%d, total:%d)",
              node.node_id or "unknown",
              node.in_degree or 0,
              node.out_degree or 0,
              node.total_degree or 0))
          end
        end
        
        ragex.show_in_float("Ragex Graph Statistics", lines)
      else
        vim.notify("No graph statistics available", vim.log.levels.WARN)
      end
    end,
    "Graph Stats"
  },
  W = { function() ragex.watch_directory(vim.fn.getcwd()) end, "Watch Directory" },
  t = { function() ragex.toggle_auto_analyze() end, "Toggle Auto-Analysis" },
  -- Advanced Graph Algorithms
  b = { function() ragex.show_betweenness_centrality() end, "Betweenness Centrality" },
  o = { function() ragex.show_closeness_centrality() end, "Closeness Centrality" },
  n = { function() ragex.show_communities("louvain") end, "Detect Communities (Louvain)" },
  l = { function() ragex.show_communities("label_propagation") end, "Detect Communities (Label Prop)" },
  e = { 
    function()
      vim.ui.select({ "graphviz", "d3" }, {
        prompt = "Export format:",
      }, function(format)
        if format then
          local ext = format == "graphviz" and "dot" or "json"
          vim.ui.input({
            prompt = "Save as: ",
            default = vim.fn.getcwd() .. "/graph." .. ext,
          }, function(filepath)
            if filepath then
              ragex.export_graph_to_file(format, filepath)
            end
          end)
        end
      end)
    end,
    "Export Graph"
  },
}

-- Register Telescope commands for Ragex
vim.api.nvim_create_user_command("RagexSearch", ragex_telescope.ragex_search, {})
vim.api.nvim_create_user_command("RagexFunctions", ragex_telescope.ragex_functions, {})
vim.api.nvim_create_user_command("RagexModules", ragex_telescope.ragex_modules, {})
vim.api.nvim_create_user_command("RagexSearchWord", ragex_telescope.ragex_search_word, {})
vim.api.nvim_create_user_command("RagexToggleAuto", function() ragex.toggle_auto_analyze() end, {})

-- Add Ragex status to lualine
local function ragex_status()
  if ragex.config.enabled then
    return "  Ragex"
  end
  return ""
end
```

This should result in the following `<leader>r` update:

<img width="1411" height="388" alt="Captura de pantalla_20260102_100918" src="https://github.com/user-attachments/assets/af24d31f-c835-4dc5-a04b-2e43e63dbc11" />

## Installation

### Prerequisites

- Elixir 1.19 or later
- Erlang/OTP 28 or later
- Python 3.x (optional, for Python code analysis)
- Node.JS (optional, for Javascript code analysis)
- ~500MB RAM for embedding model (first run downloads ~90MB)

### Build

```bash
cd ragex
mix deps.get
mix compile
```

**Note**: First compilation will take longer due to ML dependencies. The embedding model (~90MB) will download on first run and be cached at `~/.cache/huggingface/`.

## Demo

A comprehensive demo showcasing all Ragex features is available in `examples/product_cart/`.

The demo uses an intentionally mediocre e-commerce cart application to demonstrate:
- Security vulnerability scanning (8+ issues detected)
- Code complexity analysis (cyclomatic, cognitive, Halstead metrics)
- Code smell detection (long functions, deep nesting, magic numbers)
- Code duplication detection (Type I-IV clones)
- Dead code analysis (4 unused functions)
- Dependency and coupling analysis
- Impact analysis and refactoring suggestions
- AI-enhanced features (ValidationAI, AIPreview, AIRefiner, AIAnalyzer, AIInsights)

**Quick Start:**
```bash
cd examples/product_cart
./run_demo.sh
```

The demo generates 11 detailed reports showing:
- 8 security vulnerabilities (2 critical, 3 high)
- 18 code smells across 5 types
- 52 lines of duplicated code (10% of codebase)
- 28 lines of dead code (7% of codebase)
- 8 prioritized refactoring suggestions
- Expected improvement: 65% better maintainability

See [Produce Cart’s README](examples/product_cart/README.md) for full details and [Product Cart’s DEMO](examples/product_cart/DEMO.md) for step-by-step walkthrough.

## Usage

### As an MCP Server

Run the server (it will listen on both stdin and socket):

```bash
./start_mcp.sh
```

**Note**: The stdio server is validated and production-ready.

### Auto-Analyze Directories on Startup

You can configure Ragex to automatically analyze specific directories when it starts. Add to `config/config.exs`:

```elixir
config :ragex, :auto_analyze_dirs, [
  "/opt/Proyectos/MyProject",
  "~/workspace/important-lib"
]
```

This pre-loads your frequently used codebases into the knowledge graph, making them immediately available for querying. See [CONFIGURATION](stuff/docs/CONFIGURATION.md#auto-analyze-directories) for details.

### MCP Protocol Example

Initialize the server:

```json
{"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"test-client","version":"1.0"}},"id":1}
```

List available tools:

```json
{"jsonrpc":"2.0","method":"tools/list","id":2}
```

Analyze a file (with auto-detection):

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "analyze_file",
    "arguments": {
      "path": "lib/ragex.ex"
    }
  },
  "id": 3
}
```

Or specify the language explicitly:

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "analyze_file",
    "arguments": {
      "path": "script.py",
      "language": "python"
    }
  },
  "id": 3
}
```

Query the graph:

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "query_graph",
    "arguments": {
      "query_type": "find_module",
      "params": {"name": "Ragex"}
    }
  },
  "id": 4
}
```

## Development

### Running Tests

```bash
mix test
```

### Interactive Development

```bash
RAGEX_NO_SERVER=1 iex -S mix
```

```elixir
# Analyze a file
{:ok, content} = File.read("lib/ragex.ex")
{:ok, analysis} = Ragex.Analyzers.Elixir.analyze(content, "lib/ragex.ex")

# Check graph stats, it’s expected to be empty for this single file
Ragex.stats()
```

## MCP Tools Reference

### Core Analysis Tools

#### `analyze_file`

Analyzes a source file and extracts code structure into the knowledge graph.

**Parameters:**
- `path` (string, required): Path to the file
- `language` (string, optional): Programming language - `elixir`, `erlang`, `python`, `javascript`, `typescript`, or `auto` (default: auto-detect from extension)
- `generate_embeddings` (boolean, optional): Generate embeddings for semantic search (default: true)

#### `analyze_directory`

Batch analyzes all source files in a directory.

**Parameters:**
- `path` (string, required): Directory path
- `language` (string, optional): Language to filter files (default: auto-detect)
- `recursive` (boolean, optional): Recursively analyze subdirectories (default: true)
- `generate_embeddings` (boolean, optional): Generate embeddings (default: true)

#### `query_graph`

Queries the knowledge graph for code entities and relationships (symbolic search).

**Parameters:**
- `query_type` (string, required): Type of query
  - `find_module`: Find a module by name
  - `find_function`: Find a function by module and name
  - `get_calls`: Get function call relationships
  - `get_dependencies`: Get module dependencies
- `params` (object, required): Query-specific parameters

#### `list_nodes`

Lists all nodes in the knowledge graph with optional filtering.

**Parameters:**
- `node_type` (string, optional): Filter by type (module, function, etc.)
- `limit` (integer, optional): Maximum results (default: 100)

### File Watching Tools

#### `watch_directory`

Automatically re-index files when they change.

**Parameters:**
- `path` (string, required): Directory to watch

#### `unwatch_directory`

Stop watching a directory.

**Parameters:**
- `path` (string, required): Directory to stop watching

#### `list_watched`

List all watched directories.

**Parameters:** None

### Semantic Search Tools

#### `semantic_search`

Performs natural language code search using vector embeddings.

**Parameters:**
- `query` (string, required): Natural language query (e.g., "function to parse JSON")
- `limit` (integer, optional): Maximum results (default: 10)
- `threshold` (number, optional): Minimum similarity score 0.0-1.0 (default: 0.7)
- `node_type` (string, optional): Filter by type (module, function)
- `include_context` (boolean, optional): Include caller/callee context (default: false)

**Example:**
```json
{
  "query": "HTTP request handler",
  "limit": 5,
  "threshold": 0.75,
  "node_type": "function"
}
```

#### `hybrid_search`

Combines symbolic graph queries with semantic search for best results.

**Parameters:**
- `query` (string, required): Search query
- `strategy` (string, optional): Search strategy:
  - `fusion` (default): RRF fusion of both approaches
  - `semantic_first`: Semantic search then graph filtering
  - `graph_first`: Graph query then semantic ranking
- `limit` (integer, optional): Maximum results (default: 10)
- `threshold` (number, optional): Minimum similarity (default: 0.7)
- `graph_filter` (object, optional): Optional symbolic constraints
- `include_context` (boolean, optional): Include context (default: false)

**Example:**
```json
{
  "query": "database connection",
  "strategy": "fusion",
  "limit": 10,
  "graph_filter": {"module": "DB"}
}
```

#### `get_embeddings_stats`

Returns ML model and vector store statistics.

**Parameters:** None

**Returns:**
- Model information (name, dimensions, status)
- Vector store metrics (total embeddings, by type)
- Graph statistics (nodes, edges)

### Code Editing Tools

#### `edit_file`

Safely edit a single file with automatic backup, validation, and atomic operations.

**Parameters:**
- `path` (string, required): Path to the file to edit
- `changes` (array, required): List of changes to apply
  - `type` (string): `replace`, `insert`, or `delete`
  - `line_start` (integer): Starting line number (1-indexed)
  - `line_end` (integer): Ending line number (for replace/delete)
  - `content` (string): New content (for replace/insert)
- `validate` (boolean, optional): Validate syntax before applying (default: true)
- `create_backup` (boolean, optional): Create backup before editing (default: true)
- `format` (boolean, optional): Format code after editing (default: false)
- `language` (string, optional): Explicit language for validation (auto-detected from extension)

**Example:**
```json
{
  "path": "lib/my_module.ex",
  "changes": [
    {
      "type": "replace",
      "line_start": 10,
      "line_end": 15,
      "content": "def new_function do\n  :ok\nend"
    }
  ],
  "validate": true,
  "format": true
}
```

#### `edit_files`

Atomically edit multiple files with coordinated rollback on failure.

**Parameters:**
- `files` (array, required): List of files to edit
  - `path` (string): Path to the file
  - `changes` (array): List of changes (same format as `edit_file`)
  - `validate` (boolean, optional): Override transaction-level validation
  - `format` (boolean, optional): Override transaction-level formatting
  - `language` (string, optional): Explicit language for this file
- `validate` (boolean, optional): Validate all files before applying (default: true)
- `create_backup` (boolean, optional): Create backups for all files (default: true)
- `format` (boolean, optional): Format all files after editing (default: false)

**Example:**
```json
{
  "files": [
    {
      "path": "lib/module_a.ex",
      "changes": [{"type": "replace", "line_start": 5, "line_end": 5, "content": "@version \"2.0.0\""}]
    },
    {
      "path": "lib/module_b.ex",
      "changes": [{"type": "replace", "line_start": 10, "line_end": 12, "content": "# Updated"}]
    }
  ],
  "validate": true,
  "format": true
}
```

#### `validate_edit`

Preview validation of changes without applying them.

**Parameters:**
- `path` (string, required): Path to the file
- `changes` (array, required): List of changes to validate
- `language` (string, optional): Explicit language for validation

#### `rollback_edit`

Undo a recent edit by restoring from backup.

**Parameters:**
- `path` (string, required): Path to the file to rollback
- `backup_id` (string, optional): Specific backup to restore (default: most recent)

#### `edit_history`

Query backup history for a file.

**Parameters:**
- `path` (string, required): Path to the file
- `limit` (integer, optional): Maximum number of backups to return (default: 10)

#### `refactor_code`

Semantic refactoring operations using AST analysis and knowledge graph.

**Parameters:**
- `operation` (string, required): Type of refactoring - `rename_function` or `rename_module`
- `params` (object, required): Operation-specific parameters
  - For `rename_function`:
    - `module` (string): Module containing the function
    - `old_name` (string): Current function name
    - `new_name` (string): New function name
    - `arity` (integer): Function arity
  - For `rename_module`:
    - `old_name` (string): Current module name
    - `new_name` (string): New module name
- `scope` (string, optional): `module` (same file only) or `project` (all files, default: project)
- `validate` (boolean, optional): Validate before/after (default: true)
- `format` (boolean, optional): Format code after (default: true)

**Example - Rename Function:**
```json
{
  "operation": "rename_function",
  "params": {
    "module": "MyModule",
    "old_name": "old_function",
    "new_name": "new_function",
    "arity": 2
  },
  "scope": "project",
  "validate": true,
  "format": true
}
```

**Example - Rename Module:**
```json
{
  "operation": "rename_module",
  "params": {
    "old_name": "OldModule",
    "new_name": "NewModule"
  },
  "validate": true
}
```

### RAG (AI-Powered) Tools

#### `rag_query`

Query the codebase using Retrieval-Augmented Generation with AI assistance.

**Parameters:**
- `query` (string, required): Natural language query about the codebase
- `limit` (integer, optional): Maximum number of code snippets to retrieve (default: 10)
- `include_code` (boolean, optional): Include full code snippets in context (default: true)
- `provider` (string, optional): AI provider override (`deepseek_r1`)

**Example:**
```json
{
  "query": "How does authentication work in this codebase?",
  "limit": 15,
  "include_code": true
}
```

**Returns:**
- AI-generated response based on retrieved code context
- Sources count and model information

#### `rag_explain`

Explain code using RAG with AI assistance and aspect-focused analysis.

**Parameters:**
- `target` (string, required): File path or function identifier (e.g., `MyModule.function/2`)
- `aspect` (string, optional): What to explain - `purpose`, `complexity`, `dependencies`, or `all` (default: `all`)

**Example:**
```json
{
  "target": "Ragex.Graph.Store.add_node/3",
  "aspect": "complexity"
}
```

**Returns:**
- AI-generated explanation based on code analysis
- Related code context and dependencies

#### `rag_suggest`

Suggest code improvements using RAG with AI analysis.

**Parameters:**
- `target` (string, required): File path or function identifier
- `focus` (string, optional): Improvement focus - `performance`, `readability`, `testing`, `security`, or `all` (default: `all`)

**Example:**
```json
{
  "target": "lib/ragex/editor/core.ex",
  "focus": "performance"
}
```

**Returns:**
- AI-generated improvement suggestions
- Code context and rationale

**Configuration:**

RAG tools require the `DEEPSEEK_API_KEY` environment variable:

```bash
export DEEPSEEK_API_KEY="sk-xxxxxxxxxxxxx"
```

## Documentation

- [Algorithms](stuff/docs/ALGORITHMS.md) - Algorithms used
- [Usage](stuff/docs/USAGE.md) - Tips on how to use `Ragex`
- [Configuration](stuff/docs/CONFIGURATION.md) - Embedding model configuration and migration
- [Persistence](stuff/docs/PERSISTENCE.md) - Embedding cache management and performance
- [Analysis](stuff/docs/ANALYSIS.md) - Code analysis features and tools
- [Troubleshooting](stuff/docs/TROUBLESHOOTING.md) - Common issues and error messages

### Cache Management

Ragex automatically caches embeddings for faster startup:

```bash
# View cache statistics
mix ragex.cache.stats

# Clear current project cache
mix ragex.cache.clear --current

# Clear all caches
mix ragex.cache.clear --all --force
```

## TODO: Streaming Enhancements

The following streaming improvements are planned but not yet implemented:

- **Tool-call delta parsing in providers**: Currently, streaming parsers for all four providers (DeepSeek, OpenAI, Anthropic, Ollama) silently skip `tool_calls` deltas in the SSE stream. Adding index-based `function.arguments` accumulation would allow real-time thinking tokens even during intermediate tool-call steps in the agent loop. This requires per-provider work (OpenAI/DeepSeek: `delta.tool_calls[i]`; Anthropic: `content_block_start` + `input_json_delta`; Ollama: not supported by API).

- **Full MCP streaming protocol**: Emit individual JSON-RPC streaming responses (not just notifications) per chunk, allowing MCP clients to render responses incrementally. Includes cancellation support via MCP protocol.

- **Stream caching and replay**: Cache reconstructed responses from consumed streams so that repeated queries can be served from cache without re-calling the AI provider.

## Supported Languages

| Language | Extensions | Parser | Status |
|----------|-----------|--------|--------|
| Elixir | `.ex`, `.exs` | Native AST (`Code.string_to_quoted`) | ✓ Full |
| Erlang | `.erl`, `.hrl` | Native AST (`:erl_scan`, `:erl_parse`) | ✓ Full |
| Python | `.py` | Python `ast` module (subprocess) | ✓ Full |
| JavaScript/TypeScript | `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs` | Regex-based | ✗ Basic |
