# Ragex TODO

**Project Status**: Production-Ready (v0.2.0)  
**Last Updated**: January 22, 2026  
**Completed Phases**: 1-5, 8, 9, RAG (Phases 1-4, Phase 5A-C)

---

## Executive Summary

Ragex is a mature Hybrid RAG system with comprehensive capabilities for multi-language codebase analysis, semantic search, safe code editing, and AI-powered code intelligence. This document outlines remaining work, improvements, and future enhancements.

**Current State:**
- 17,600+ lines of production code (including RAG system with streaming + notifications)
- 377 tests passing (25+ test files)
- 28 MCP tools (analysis, search, editing, refactoring, RAG, streaming RAG, monitoring)
- 6 MCP resources (read-only state access)
- 6 MCP prompts (workflow templates)
- 4 languages fully supported (Elixir, Erlang, Python, JS/TS)
- Metastatic MetaAST integration for enhanced analysis
- Phase 8: Advanced graph algorithms (complete)
- Phase 9: MCP resources and prompts (complete)
- **NEW**: RAG System with Multi-Provider AI (Phases 1-4, Phase 5A-C complete - January 22, 2026)

---

## RAG System Implementation (Completed - January 22, 2026)

**Status**: Production-Ready  
**Phases 1-4 Complete**

### Completed Features

#### Phase 1: AI Provider Abstraction
- [x] AI provider behaviour and configuration system
- [x] DeepSeek R1 provider with OpenAI-compatible API
  * Support for `deepseek-chat` and `deepseek-reasoner` models
  * Synchronous and streaming generation
  * Full error handling and validation
- [x] Provider registry GenServer
- [x] Runtime configuration via environment variables
- [x] Application-level integration and validation

#### Phase 2: Metastatic Integration
- [x] Metastatic analyzer wrapper for enhanced code analysis
  * Support for Elixir, Erlang, Python, Ruby
  * Graceful fallback to native analyzers
- [x] Feature flag system (`use_metastatic`, `fallback_to_native_analyzers`)
- [x] Automatic extension detection and analyzer selection

#### Phase 3: RAG Pipeline
- [x] Context builder for formatting retrieval results
- [x] Prompt template system (query/explain/suggest)
- [x] Full RAG pipeline orchestration:
  * Retrieval via hybrid search
  * Context building with truncation
  * Prompt engineering
  * AI generation
  * Post-processing
- [x] Three MCP tools:
  * `rag_query` - Query codebase with AI assistance
  * `rag_explain` - Explain code with aspect focus
  * `rag_suggest` - Suggest improvements with focus areas

### Phase 4: Enhanced AI Capabilities (Completed - January 22, 2026)

**Status**: Production-Ready  
**Completed**: January 22, 2026

#### Phase 4A: Additional AI Providers
- [x] OpenAI provider (GPT-4, GPT-4-turbo, GPT-3.5-turbo)
- [x] Anthropic provider (Claude 3 Opus, Sonnet, Haiku)
- [x] Ollama provider for local LLMs (llama2, mistral, codellama, phi)
- [x] Multi-provider configuration with fallback support
- [x] Provider registry with dynamic selection

#### Phase 4B: AI Response Caching
- [x] ETS-based caching with SHA256 key generation
- [x] TTL-based expiration (configurable per operation)
- [x] LRU eviction when max size reached
- [x] Automatic cleanup of expired entries
- [x] Cache hit/miss metrics tracking
- [x] Mix tasks for cache management (stats, clear)
- [x] Integration with RAG pipeline

#### Phase 4C: Cost Tracking and Rate Limiting
- [x] Per-provider usage tracking (requests, tokens, costs)
- [x] Real-time cost estimation with current pricing
- [x] Time-windowed rate limiting (minute, hour, day)
- [x] Mix tasks for usage monitoring
- [x] MCP tools for usage/cache statistics
- [x] Automatic rate limit enforcement

**Deliverables:**
- 932 lines of new code (cache, usage tracking, Mix tasks)
- 3 new MCP tools (get_ai_usage, get_ai_cache_stats, clear_ai_cache)
- Updated configuration for all providers
- All 343 tests passing
- Zero breaking changes

### Phase 5: Advanced RAG Enhancements (In Progress)

**Priority**: CRITICAL - Foundation for Phases 10-12  
**Estimated Effort**: 3-4 weeks  
**Dependencies**: None (enables Phases 10-12)

**Strategic Importance**: Phase 5 is the critical foundation for Phases 10 (Enhanced Refactoring), 11 (Advanced Analysis), and 12 (Developer Experience). All features in Phase 5 should be designed to support the needs of Phases 10-12, though additional capabilities may be needed during those phases.

#### 5A: Streaming Responses (COMPLETE - January 22, 2026)
- [x] Streaming responses via provider APIs (SSE/NDJSON)
- [x] Server-sent events parsing (OpenAI, Anthropic, DeepSeek)
- [x] NDJSON streaming support (Ollama)
- [x] Task-based concurrent streaming with Stream.resource
- [x] Token usage tracking in streaming mode
- [x] Pipeline integration (stream_query, stream_explain, stream_suggest)
- [x] MCP tools (rag_query_stream, rag_explain_stream, rag_suggest_stream)
- [x] Documentation (STREAMING.md)

**Deliverables:**
- 600 lines of new streaming code across 5 files
- All 4 providers support streaming (OpenAI, Anthropic, DeepSeek, Ollama)
- 3 new MCP tools for streaming RAG operations
- STREAMING.md documentation (327 lines)
- All 343 tests passing (zero breaking changes)

#### 5B: Enhanced Retrieval Strategies (COMPLETE - January 22, 2026)
- [x] MetaAST-enhanced retrieval (leverage Metastatic metadata)
- [x] Cross-language semantic queries
- [x] Context-aware ranking
- [x] Query expansion and refinement

#### 5C: MCP Streaming Notifications (COMPLETE - January 22, 2026)
- [x] Full MCP notification protocol implementation
- [x] Server notification sending capability (GenServer cast)
- [x] Editor progress notifications (transaction lifecycle)
- [x] Analyzer progress notifications (directory analysis)
- [x] Real-time progress tracking for long-running operations
- [x] Documentation (PHASE5C_COMPLETE.md)

**Deliverables:**
- Notification infrastructure in MCP server
- Progress tracking in Transaction and Directory modules
- 377 tests passing (all edit tool tests comprehensive)
- PHASE5C_COMPLETE.md documentation

**Note**: This phase provides essential infrastructure that Phases 10-12 will heavily depend on. Implementation should anticipate needs of refactoring (Phase 10), analysis (Phase 11), and UX improvements (Phase 12).

---

## Phase 6: Production Optimizations (Deferred)

**Priority**: Medium (after Phases 10-12)  
**Estimated Effort**: 3-4 weeks  
**Dependencies**: Phases 5, 10, 11, 12 should be complete first

### 6A: Performance Profiling and Optimization
- [ ] Profile hot paths with `:fprof` or Benchee
- [ ] Optimize PageRank convergence (adaptive tolerance)
- [ ] Parallelize path finding for multiple queries
- [ ] Optimize ETS table structure (consider ordered_set for specific queries)
- [ ] Benchmark and optimize vector search operations
- [ ] Cache PageRank results with TTL
- [ ] Optimize embedding batch processing
- [ ] Profile memory usage patterns
- [ ] Add performance regression tests

**Deliverables:**
- Performance benchmarks baseline
- Optimization implementation
- Updated PERFORMANCE.md documentation

### 6B: Advanced Caching Strategies
- [ ] Implement LRU cache for graph queries
- [ ] Add query result caching with invalidation
- [ ] Optimize embedding cache loading (stream vs. load all)
- [ ] Add incremental PageRank updates (delta computation)
- [ ] Cache community detection results
- [ ] Implement stale cache detection and warning
- [ ] Add cache warming strategies
- [ ] Optimize cache serialization format (consider compression)

**Deliverables:**
- Cache management module
- Cache invalidation strategies
- Updated PERSISTENCE.md

### 6C: Scaling Improvements
- [ ] Add graph partitioning for very large codebases (>100k entities)
- [ ] Implement distributed graph storage (consider :pg or Registry)
- [ ] Add query pagination support
- [ ] Optimize for low-memory environments
- [ ] Add streaming analysis for large directories
- [ ] Implement progressive loading UI feedback
- [ ] Add cancellable operations support
- [ ] Memory pressure detection and adaptation

**Deliverables:**
- Scalability documentation
- Large codebase benchmarks
- Memory optimization guide

### 6D: Reliability and Error Recovery
- [ ] Add circuit breakers for external processes (Python, Node.js)
- [ ] Implement graceful degradation for ML model failures
- [ ] Add health check endpoints
- [ ] Improve error messages with actionable suggestions
- [ ] Add retry logic with exponential backoff
- [ ] Implement crash recovery for MCP server
- [ ] Add state persistence for long-running operations
- [ ] Improve validation error reporting

**Deliverables:**
- Error recovery module
- Health monitoring
- TROUBLESHOOTING.md updates

---

## Phase 7: Additional Language Support (Deferred)

**Priority**: Low (after Phases 10-12)  
**Estimated Effort**: 2-3 weeks per language  
**Dependencies**: Phases 5, 10, 11, 12 should be complete first

**IMPORTANT**: Ragex does NOT implement AST analyzers. All language analysis is delegated to the `metastatic` dependency. To add new language support:

1. **Update Metastatic**: Add language support to the Metastatic library
2. **Update Ragex**: Add language-specific validator, formatter integration, and tests
3. **No AST Implementation**: Ragex only wraps Metastatic's analysis capabilities

### 7A: Go Language Support
- [ ] Update Metastatic to support Go (MetaAST integration)
- [ ] Add Go validator in Ragex
- [ ] Integrate `gofmt` for formatting
- [ ] Add Go-specific refactoring support (via Metastatic)
- [ ] Add comprehensive tests
- [ ] Update documentation

**Extensions**: `.go`  
**Implementation**: Via Metastatic library (not in Ragex)

### 7B: Rust Language Support  
- [ ] Update Metastatic to support Rust (MetaAST integration)
- [ ] Add Rust validator in Ragex
- [ ] Integrate `rustfmt` for formatting
- [ ] Add Rust-specific refactoring support (via Metastatic)
- [ ] Add comprehensive tests
- [ ] Update documentation

**Extensions**: `.rs`  
**Implementation**: Via Metastatic library (not in Ragex)

### 7C: Java Language Support
- [ ] Update Metastatic to support Java (MetaAST integration)
- [ ] Add Java validator in Ragex
- [ ] Integrate Java formatter
- [ ] Add Java-specific refactoring support (via Metastatic)
- [ ] Add comprehensive tests
- [ ] Update documentation

**Extensions**: `.java`  
**Implementation**: Via Metastatic library (not in Ragex)

### 7D: Improved JavaScript/TypeScript Support
**Current State**: Basic regex-based parsing via native analyzer

- [ ] Update Metastatic to improve JS/TS support (MetaAST integration)
- [ ] Add TypeScript type information extraction (via Metastatic)
- [ ] Improve import/export tracking
- [ ] Add JSX/TSX component analysis
- [ ] Add comprehensive tests
- [ ] Update documentation

**Extensions**: `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`  
**Implementation**: Via Metastatic library (not in Ragex)

**Note**: Ruby support already exists in Metastatic. No additional work needed unless refactoring support is required.

---

## Phase 10: Enhanced Refactoring Capabilities (High Priority)

**Priority**: High (after Phase 5)  
**Estimated Effort**: 4-5 weeks  
**Dependencies**: Phase 5 (critical foundation)

### 10A: Additional Refactoring Operations
- [ ] Extract function refactoring
- [ ] Inline function refactoring
- [ ] Extract module refactoring
- [ ] Move function to different module
- [ ] Change function signature (add/remove parameters)
- [ ] Convert private to public (and vice versa)
- [ ] Rename parameter refactoring
- [ ] Add/remove module attributes

**Deliverables:**
- Extended refactoring API
- MCP tools for new operations
- Comprehensive tests

### 10B: Cross-Language Refactoring
- [ ] Extend semantic refactoring to Erlang
- [ ] Extend semantic refactoring to Python
- [ ] Extend semantic refactoring to JavaScript/TypeScript
- [ ] Support polyglot projects (Elixir + Erlang)
- [ ] Handle language boundaries (FFI, NIFs)

**Deliverables:**
- Multi-language refactoring support
- Cross-language call tracking

### 10C: Refactoring Previews and Diffs
- [ ] Generate unified diffs for refactoring operations
- [ ] Add refactoring simulation mode (dry-run)
- [ ] Implement refactoring conflict detection
- [ ] Add refactoring undo stack (beyond simple rollback)
- [ ] Generate refactoring reports
- [ ] Add refactoring visualization

**Deliverables:**
- Preview and diff tools
- Conflict resolution strategies

---

## Phase 11: Advanced Analysis and Insights (High Priority)

**Priority**: High (after Phase 5)  
**Estimated Effort**: 3-4 weeks  
**Dependencies**: Phase 5 (critical foundation)

### 11A: Code Quality Metrics
- [ ] Cyclomatic complexity calculation
- [ ] Code duplication detection
- [ ] Technical debt scoring
- [ ] Code smell detection (God functions, feature envy, etc.)
- [ ] Maintainability index
- [ ] Test coverage correlation
- [ ] Documentation coverage

**Deliverables:**
- Quality metrics module
- MCP tools for quality analysis
- Quality reports

### 11B: Dependency Analysis
- [ ] Visualize module dependencies
- [ ] Detect circular dependencies
- [ ] Identify unused code
- [ ] Find dead code paths
- [ ] Analyze coupling metrics (afferent/efferent)
- [ ] Suggest decoupling strategies
- [ ] Generate dependency graphs

**Deliverables:**
- Dependency analysis tools
- Visualization export formats
- Architectural recommendations

### 11C: Change Impact Prediction
- [ ] Machine learning for change risk prediction
- [ ] Historical change analysis
- [ ] Test prioritization based on changes
- [ ] Regression risk scoring
- [ ] Suggest reviewers based on code ownership
- [ ] Estimate effort for refactoring

**Deliverables:**
- Prediction models
- Risk assessment tools
- Integration with VCS

---

## Phase 12: Developer Experience Improvements (High Priority)

**Priority**: High (after Phase 5)  
**Estimated Effort**: 2-3 weeks  
**Dependencies**: Phase 5 (critical foundation)

### 12A: Enhanced Editor Integrations
- [ ] Full NeoVim/LunarVim plugin distribution
- [ ] VSCode extension
- [ ] Emacs integration
- [ ] JetBrains IDE plugin
- [ ] Sublime Text integration
- [ ] Documentation and tutorials

**Deliverables:**
- Editor plugins/extensions
- Integration guides
- Demo videos

### 12B: CLI Improvements
- [ ] Rich TUI for interactive analysis
- [ ] Progress bars and status indicators
- [ ] Colored output and formatting
- [ ] Interactive refactoring wizard
- [ ] Configuration wizard
- [ ] Shell completion scripts
- [ ] Man pages

**Deliverables:**
- Enhanced CLI experience
- Interactive tools
- Documentation updates

### 12C: Web UI Dashboard
- [ ] Real-time graph visualization
- [ ] Interactive codebase exploration
- [ ] Refactoring workflow interface
- [ ] Metrics and analytics dashboard
- [ ] Search interface with previews
- [ ] Configuration management UI
- [ ] Phoenix LiveView-based implementation

**Deliverables:**
- Web dashboard application
- API endpoints
- User documentation

---

## Phase 13: Ecosystem Integration (Future)

**Priority**: Low-Medium  
**Estimated Effort**: 3-4 weeks

### 13A: Version Control Integration
- [ ] Git hooks for automatic analysis
- [ ] Pre-commit validation
- [ ] Post-merge analysis
- [ ] Branch comparison
- [ ] Pull request analysis
- [ ] Commit message suggestions
- [ ] Blame integration

**Deliverables:**
- Git integration module
- Hook scripts
- VCS documentation

### 13B: CI/CD Integration
- [ ] GitHub Actions integration
- [ ] GitLab CI integration
- [ ] Jenkins plugin
- [ ] CircleCI orb
- [ ] Quality gate enforcement
- [ ] Automated refactoring suggestions
- [ ] Regression detection

**Deliverables:**
- CI/CD integrations
- Example workflows
- Integration guides

### 13C: Project Management Integration
- [ ] Jira integration (link code to issues)
- [ ] GitHub Issues integration
- [ ] Technical debt tracking
- [ ] Effort estimation
- [ ] Sprint planning insights
- [ ] Team productivity metrics

**Deliverables:**
- PM tool integrations
- Tracking dashboards
- Reporting tools

---

## Immediate Priorities (Next 2-3 Months)

### CRITICAL PATH

**Phase 5 → Phase 10 → Phase 11 → Phase 12**

This is the strategic path forward. Phase 5 provides the foundation; Phases 10-12 deliver user value.

### Phase 5: Advanced RAG Enhancements (NEXT - 3-4 weeks)
**Why Critical**: Foundation for everything that follows

1. **Streaming Responses** (1 week)
   - Essential for good UX in Phases 10-12
   - Real-time feedback during refactoring

2. **Enhanced Retrieval** (1-2 weeks)
   - MetaAST-enhanced strategies
   - Cross-language semantic queries
   - Better context for refactoring decisions

3. **Production AI Features** (1 week)
   - Health checks and failover
   - Cost analytics
   - Reliability for production use

### Phase 10: Enhanced Refactoring (after Phase 5 - 4-5 weeks)
**Depends on**: Phase 5 streaming and retrieval

- Extract/inline function refactoring
- Refactoring previews with diffs
- Cross-language refactoring support
- Move function between modules

### Phase 11: Advanced Analysis (after Phase 5 - 3-4 weeks)
**Depends on**: Phase 5 retrieval enhancements

- Code quality metrics
- Dependency analysis
- Change impact prediction
- Technical debt scoring

### Phase 12: Developer Experience (after Phase 5 - 2-3 weeks)
**Depends on**: Phase 5 streaming

- VSCode extension
- Enhanced CLI with progress indicators
- Web dashboard (Phoenix LiveView)
- Better editor integrations

### Lower Priority (after Phases 5, 10-12)

- **Phase 6**: Production optimizations (performance tuning)
- **Phase 7**: Additional languages (via Metastatic updates)
- **Phase 13**: Ecosystem integration (CI/CD, VCS)

---

## Technical Debt and Maintenance

### Known Issues

1. **Phase 5E Test Failures**
   - 4 integration tests failing due to graph state management
   - AST manipulation works correctly (unit tests pass)
   - Need to refactor test infrastructure
   - Priority: Medium

2. **JavaScript Analyzer Limitations**
   - Regex-based parsing is fragile
   - Missing nested function detection
   - Priority: High (addressed in Phase 7E)

3. **Memory Usage**
   - ML model requires ~400MB RAM
   - Large codebases (>50k entities) can consume significant memory
   - Priority: Medium (addressed in Phase 6C)

### Code Quality Improvements

- [ ] Increase test coverage to 95%+
- [ ] Add property-based tests (StreamData)
- [ ] Improve type specs consistency
- [ ] Add dialyzer checks to CI
- [ ] Refactor large modules (>500 lines)
- [ ] Standardize error tuple formats
- [ ] Add logging consistency
- [ ] Document all public APIs

### Documentation Gaps

- [ ] Create GETTING_STARTED.md for new users
- [ ] Add architecture decision records (ADRs)
- [ ] Document MCP protocol implementation details
- [ ] Add troubleshooting flowcharts
- [ ] Create video tutorials
- [ ] Document performance tuning strategies
- [ ] Add migration guides for major versions
- [ ] Create API reference documentation

---

## Research and Experiments

### ML and Embeddings

- [ ] Experiment with code-specific models (CodeBERT, GraphCodeBERT)
- [ ] Fine-tune embeddings on specific codebases
- [ ] Investigate cross-lingual code embeddings
- [ ] Test alternative similarity metrics
- [ ] Experiment with dimensionality reduction
- [ ] Add support for custom embedding models (via API)
- [ ] Investigate federated learning for collaborative embeddings

### Graph Algorithms

- [ ] Implement incremental PageRank (for real-time updates)
- [ ] Add temporal graph analysis (code evolution over time)
- [ ] Experiment with graph neural networks
- [ ] Implement personalized PageRank for context-aware search
- [ ] Add graph compression techniques for large codebases
- [ ] Investigate probabilistic graph structures

### Code Understanding

- [ ] Natural language code summaries (with LLM integration)
- [ ] Automatic test generation suggestions
- [ ] Code clone detection using embeddings
- [ ] Bug prediction using historical data
- [ ] Code review automation
- [ ] Smart merge conflict resolution

---

## Community and Ecosystem

### Open Source

- [ ] Publish to Hex.pm
- [ ] Create Homebrew formula
- [ ] Submit to awesome-elixir list
- [ ] Create project website
- [ ] Set up community forum or Discord
- [ ] Establish contributor guidelines
- [ ] Add code of conduct
- [ ] Create issue templates

### Documentation and Outreach

- [ ] Write blog posts on architecture
- [ ] Present at ElixirConf or similar
- [ ] Create showcase projects
- [ ] Record demo videos
- [ ] Write case studies
- [ ] Create comparison with alternatives
- [ ] Build example integrations

### Partnerships

- [ ] Integrate with popular Elixir tools (ExDoc, Credo, etc.)
- [ ] Partner with editor plugin maintainers
- [ ] Collaborate with ML/embedding model researchers
- [ ] Engage with MCP ecosystem
- [ ] Support enterprise adoption

---

## Version Roadmap

### v0.3.0 (Next Minor Release) - Q1 2026
- RAG Phase 4: Multi-provider AI with caching (COMPLETE)
- Phase 6A: Performance optimizations
- Phase 6D: Reliability improvements
- Phase 7E: Better JS/TS support
- Documentation improvements
- Bug fixes and stability

### v0.4.0 - Q2 2026
- Phase 6B-C: Advanced caching and scaling
- Phase 10C: Refactoring previews
- Phase 12A: VSCode extension
- Additional language support (Go or Rust)

### v0.5.0 - Q3 2026
- Phase 11A: Code quality metrics
- Phase 12B-C: Enhanced CLI and Web UI
- Phase 13A: VCS integration
- Cross-language refactoring

### v1.0.0 - Q4 2026 (Production Release)
- All Phase 6-7 features complete
- Comprehensive documentation
- Production hardening
- Enterprise-ready features
- Full test coverage
- Performance guarantees

---

## Success Metrics

### Technical Metrics
- Test coverage > 95%
- Query performance < 100ms (p95)
- Memory usage < 1GB for 100k entities
- Support 5+ languages fully
- 100% uptime for MCP server

### Adoption Metrics
- 1,000+ GitHub stars
- 100+ production deployments
- 10+ editor integrations
- Active community contributions

### Quality Metrics
- < 5% bug rate
- < 24h critical bug response
- < 1 week minor release cycle
- 100% documentation coverage

---

## Contributing

Areas where contributions would be most valuable:

1. **Language Analyzers**: Go, Rust, Java, Ruby
2. **Editor Integrations**: VSCode, IntelliJ, Emacs
3. **Documentation**: Tutorials, examples, translations
4. **Testing**: Edge cases, performance tests, integration tests
5. **Optimizations**: Performance, memory, scalability
6. **Features**: New refactoring operations, analysis tools

---

## Notes and Ideas

### Random Ideas for Future Exploration

- **Collaborative Ragex**: Share embeddings across team
- **Cloud-hosted Ragex**: SaaS offering for teams
- **Ragex API**: RESTful API alongside MCP
- **Plugin System**: Allow third-party extensions
- **Multi-project Analysis**: Analyze dependencies across projects
- **AI Code Review**: Automated review using Ragex + LLM
- **Code Generation**: Generate code from natural language + context
- **Smart Merge**: Better conflict resolution using semantic understanding
- **Code Search Engine**: Public code search powered by Ragex
- **Learning Platform**: Help developers learn codebases faster

### Technical Explorations

- **Persistent Graph Storage**: Consider RocksDB or Mnesia
- **Distributed Ragex**: Multiple instances coordinating
- **Streaming Analysis**: Real-time code analysis as you type
- **Offline Mode**: Full functionality without internet
- **Mobile Support**: Ragex on tablets/phones
- **Voice Interface**: Query code using voice commands

---

## Conclusion

Ragex has achieved production readiness with comprehensive features across analysis, search, editing, and refactoring. The roadmap focuses on:

1. **Immediate**: Performance, reliability, and developer experience
2. **Short-term**: Additional languages and better tooling
3. **Long-term**: Advanced features and ecosystem growth

The project is well-positioned for adoption and has a clear path forward to v1.0.

---

**Project Health**: Excellent  
**Development Velocity**: High  
**Community Interest**: Growing  
**Production Readiness**: Yes

Last updated: January 22, 2026
