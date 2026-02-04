# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-01-27

### Added
- Comprehensive library packaging for Hex publication
- ExDoc documentation generation with logo and assets
- Module grouping and documentation extras
- Quality aliases for CI/CD integration
- Dialyzer configuration with ignore patterns

### Changed
- Updated project structure to library format
- Enhanced mix.exs with package metadata
- Improved dependency management
- Updated Metastatic dependency to `~> 0.5`

## [0.1.0] - 2026-01-24

### Added

#### Core Features
- MCP Server Protocol: JSON-RPC 2.0 over stdio and socket
- Multi-language code analysis (Elixir, Erlang, Python, JavaScript/TypeScript)
- Knowledge graph with ETS-based storage
- Local ML embeddings via Bumblebee (sentence-transformers/all-MiniLM-L6-v2)
- Semantic search and hybrid retrieval (RRF)
- Advanced graph algorithms (PageRank, centrality, community detection)

#### Code Editing Capabilities
- Safe file editing with atomic operations and backups
- Multi-language syntax validation
- Multi-file atomic transactions
- Semantic refactoring (rename function/module)
- Advanced refactoring operations (8 types: extract_function, inline_function, etc.)
- Format integration (mix, rebar3, black, prettier)

#### Analysis & Quality
- Code duplication detection (AST-based Type I-IV clones)
- Dead code detection (interprocedural + intraprocedural)
- Dependency analysis and coupling metrics
- Impact analysis with risk scoring
- Automated refactoring suggestions with RAG-powered advice

#### AI Features
- AI-enhanced validation error explanations
- Refactoring preview with risk assessment
- Dead code false positive reduction
- Semantic Type IV clone detection
- Architectural insights for coupling/dependencies
- Feature flags with graceful degradation
- Automatic caching (3-7 day TTLs)

#### Production Features
- Custom embedding models (4 pre-configured)
- Embedding persistence and caching
- Incremental updates with file tracking
- Path finding limits for dense graphs
- MCP streaming notifications
- Graph visualization (Graphviz DOT, D3.js JSON)

#### MCP Tools (15 total)
- Code analysis: analyze_file, analyze_directory, query_graph, list_nodes
- Semantic search: semantic_search, hybrid_search, get_embeddings_stats
- Graph algorithms: find_paths, graph_stats, betweenness_centrality, closeness_centrality, detect_communities, export_graph
- Code editing: edit_file, validate_edit, rollback_edit, edit_history, edit_files, refactor_code, advanced_refactor
- Analysis: find_duplicates, find_similar_code, find_dead_code, analyze_dead_code_patterns
- Quality: analyze_dependencies, find_circular_dependencies, coupling_report, analyze_quality, quality_report, find_complex_code
- Impact: analyze_impact, estimate_refactoring_effort, risk_assessment
- Suggestions: suggest_refactorings, explain_suggestion
- AI features: validate_with_ai, preview_refactor (AI-enhanced)

#### MCP Resources
- Graph statistics, cache status, model configuration
- Project index, algorithm catalog, analysis summary

#### MCP Prompts
- Analyze Architecture (shallow/deep)
- Find Impact, Explain Code Flow

### Documentation
- Comprehensive README with features overview
- ALGORITHMS.md: Graph algorithm reference
- ANALYSIS.md: Code analysis guide
- SUGGESTIONS.md: Refactoring suggestions guide
- CONFIGURATION.md: Configuration reference
- PERSISTENCE.md: Caching and persistence
- PROMPTS.md: MCP prompts guide
- RESOURCES.md: MCP resources reference
- STREAMING.md: Streaming notifications guide
- USAGE.md: Usage examples

## [Unreleased]

### Added
- JSON output cleanup for analysis tools to suppress "no issue" indicators
  - Automatically removes false `has_*?` boolean flags
  - Removes zero-value count metrics (critical_count, total_issues, etc.)
  - Removes empty collections (issues: [], by_severity: {})
  - Applies recursively to nested structures, including individual file results
  - Preserves structs (DateTime, etc.) without modification
  - **Filters out entire file results** from `results` arrays when no issues/smells and no errors
  - Results in 75% size reduction for clean files, cleaner output overall
  - Affects analyze_business_logic and detect_smells MCP tools
  - Only shows files with actionable findings or errors in `results` array
  - See docs/JSON_CLEANUP.md for full details

### Planned
- Additional language support (Go, Rust, Java)
- Cross-language refactoring via Metastatic
- Production optimizations
- Enhanced semantic analysis for advanced refactoring operations

[0.2.0]: https://github.com/Oeditus/ragex/releases/tag/v0.2.0
[0.1.0]: https://github.com/Oeditus/ragex/releases/tag/v0.1.0
