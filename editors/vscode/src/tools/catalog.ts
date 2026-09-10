import * as vscode from "vscode";

/**
 * The Ragex tool catalog.
 *
 * A single declarative table describing every MCP tool the extension knows
 * about: its category, how to build its arguments from the editor context, and
 * which timeout class it belongs to. Commands, the generic `Ragex: Call Tool…`
 * runner, and the tool menu are all generated from this catalog.
 */

export type TimeoutClass = "fast" | "default" | "slow" | "very_slow";

export const TIMEOUTS: Record<TimeoutClass, number> = {
  fast: 15000,
  default: 60000,
  slow: 180000,
  very_slow: 300000,
};

export interface ToolContext {
  /** Absolute path of the active editor's file ("" if untitled). */
  path: string;
  /** Path relative to the project root. */
  relpath: string;
  /** Project root. */
  cwd: string;
  /** Word under the cursor ("" if none). */
  word: string;
  /** Prompt for a string; resolves to undefined when cancelled. */
  input(prompt: string, value?: string): Promise<string | undefined>;
  /** Prompt for a choice; resolves to undefined when cancelled. */
  select(prompt: string, items: string[]): Promise<string | undefined>;
}

export interface ToolSpec {
  name: string;
  category: string;
  desc: string;
  timeout?: TimeoutClass;
  /** Build the tool arguments from the editor context. Return undefined to cancel. */
  args(ctx: ToolContext): Promise<Record<string, unknown> | undefined>;
}

const pathArg = async (ctx: ToolContext) => ({ path: ctx.path });
const dirArg = async (ctx: ToolContext) => ({ path: ctx.cwd });

async function targetInput(ctx: ToolContext, prompt = "Target (Module.function/arity or Module): ") {
  const value = await ctx.input(prompt);
  return value ? { target: value } : undefined;
}

export const TOOLS: ToolSpec[] = [
  // ── Analysis ───────────────────────────────────────────────────────────
  {
    name: "analyze_file",
    category: "Analysis",
    desc: "Index the current file into the knowledge graph",
    timeout: "default",
    args: pathArg,
  },
  {
    name: "analyze_directory",
    category: "Analysis",
    desc: "Index the whole project directory",
    timeout: "slow",
    args: dirArg,
  },
  {
    name: "watch_directory",
    category: "Analysis",
    desc: "Watch the project and auto-reindex on change",
    timeout: "fast",
    args: dirArg,
  },
  {
    name: "unwatch_directory",
    category: "Analysis",
    desc: "Stop watching the project",
    timeout: "fast",
    args: dirArg,
  },
  {
    name: "list_watched",
    category: "Analysis",
    desc: "List watched directories",
    timeout: "fast",
    args: async () => ({}),
  },
  {
    name: "graph_stats",
    category: "Analysis",
    desc: "Knowledge graph statistics",
    timeout: "fast",
    args: async () => ({}),
  },
  {
    name: "list_nodes",
    category: "Analysis",
    desc: "List indexed modules / functions",
    timeout: "default",
    args: async (ctx) => {
      const kind = await ctx.select("Node type:", ["module", "function", "all"]);
      if (kind === undefined) {
        return undefined;
      }
      return kind === "all" ? { limit: 200 } : { node_type: kind, limit: 200 };
    },
  },

  // ── Search ─────────────────────────────────────────────────────────────
  {
    name: "semantic_search",
    category: "Search",
    desc: "Natural-language semantic code search",
    timeout: "default",
    args: async (ctx) => {
      const q = await ctx.input("Semantic query:", ctx.word);
      return q ? { query: q, limit: 30, include_context: true } : undefined;
    },
  },
  {
    name: "hybrid_search",
    category: "Search",
    desc: "Hybrid (semantic + graph) code search",
    timeout: "default",
    args: async (ctx) => {
      const q = await ctx.input("Hybrid query:", ctx.word);
      return q ? { query: q, limit: 30, include_context: true, strategy: "fusion" } : undefined;
    },
  },
  {
    name: "search_strings",
    category: "Search",
    desc: "Search indexed string literals",
    timeout: "default",
    args: async (ctx) => {
      const q = await ctx.input("String to search:", ctx.word);
      return q ? { query: q, limit: 40 } : undefined;
    },
  },
  {
    name: "expand_query",
    category: "Search",
    desc: "Expand a query with synonyms / cross-language terms",
    timeout: "default",
    args: async (ctx) => {
      const q = await ctx.input("Query to expand:", ctx.word);
      return q ? { query: q } : undefined;
    },
  },
  {
    name: "get_embeddings_stats",
    category: "Search",
    desc: "Embedding model / vector store statistics",
    timeout: "fast",
    args: async () => ({}),
  },

  // ── Graph ──────────────────────────────────────────────────────────────
  {
    name: "find_callers",
    category: "Graph",
    desc: "Find direct callers of a function",
    timeout: "default",
    args: async (ctx) => {
      const module = await ctx.input("Module (e.g. MyApp.Foo):");
      if (!module) {
        return undefined;
      }
      const func = await ctx.input("Function name:", ctx.word);
      return func ? { module, function_name: func } : undefined;
    },
  },
  {
    name: "find_paths",
    category: "Graph",
    desc: "Find call chains between two functions",
    timeout: "default",
    args: async (ctx) => {
      const from = await ctx.input("From (Module.function/arity):");
      if (!from) {
        return undefined;
      }
      const to = await ctx.input("To (Module.function/arity):");
      return to ? { from, to, max_depth: 10 } : undefined;
    },
  },
  {
    name: "betweenness_centrality",
    category: "Graph",
    desc: "Bridge / bottleneck functions",
    timeout: "default",
    args: async () => ({ normalize: true }),
  },
  {
    name: "closeness_centrality",
    category: "Graph",
    desc: "Most central functions",
    timeout: "default",
    args: async () => ({ normalize: true }),
  },
  {
    name: "detect_communities",
    category: "Graph",
    desc: "Detect architectural modules (communities)",
    timeout: "default",
    args: async (ctx) => {
      const algo = await ctx.select("Algorithm:", ["louvain", "label_propagation"]);
      return algo ? { algorithm: algo } : undefined;
    },
  },
  {
    name: "export_graph",
    category: "Graph",
    desc: "Export the call graph (Graphviz / D3)",
    timeout: "default",
    args: async (ctx) => {
      const format = await ctx.select("Export format:", ["graphviz", "d3"]);
      return format ? { format } : undefined;
    },
  },

  // ── Quality ────────────────────────────────────────────────────────────
  {
    name: "analyze_quality",
    category: "Quality",
    desc: "Per-function quality metrics for the current file",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "quality_report",
    category: "Quality",
    desc: "Aggregated quality report",
    timeout: "default",
    args: async () => ({ report_type: "summary", format: "text" }),
  },
  {
    name: "find_complex_code",
    category: "Quality",
    desc: "Functions exceeding a complexity threshold",
    timeout: "default",
    args: async () => ({ metric: "cyclomatic", threshold: 10, show_functions: true }),
  },
  {
    name: "detect_smells",
    category: "Quality",
    desc: "Structural code smells for the current file",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "find_duplicates",
    category: "Quality",
    desc: "AST-based duplicate detection (project)",
    timeout: "slow",
    args: dirArg,
  },
  {
    name: "find_similar_code",
    category: "Quality",
    desc: "Semantically similar functions",
    timeout: "slow",
    args: async () => ({ threshold: 0.9, limit: 50 }),
  },
  {
    name: "find_dead_code",
    category: "Quality",
    desc: "Find unused functions",
    timeout: "slow",
    args: async () => ({ scope: "all", min_confidence: 0.5, format: "summary" }),
  },
  {
    name: "analyze_dead_code_patterns",
    category: "Quality",
    desc: "Unreachable code inside live functions (current file)",
    timeout: "slow",
    args: pathArg,
  },

  // ── Dependencies ───────────────────────────────────────────────────────
  {
    name: "analyze_dependencies",
    category: "Dependencies",
    desc: "Coupling metrics for all modules",
    timeout: "default",
    args: async () => ({ format: "summary" }),
  },
  {
    name: "coupling_report",
    category: "Dependencies",
    desc: "Afferent/efferent coupling report",
    timeout: "default",
    args: async () => ({ format: "text", sort_by: "instability" }),
  },
  {
    name: "find_circular_dependencies",
    category: "Dependencies",
    desc: "Circular dependencies",
    timeout: "default",
    args: async () => ({ scope: "module", limit: 100 }),
  },

  // ── Security ───────────────────────────────────────────────────────────
  {
    name: "scan_security",
    category: "Security",
    desc: "Fast security scan of the current file",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "analyze_security_issues",
    category: "Security",
    desc: "Full CWE-mapped security analysis (current file)",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "check_secrets",
    category: "Security",
    desc: "Hardcoded secrets in the current file",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "security_audit",
    category: "Security",
    desc: "Project-wide security audit report",
    timeout: "very_slow",
    args: async (ctx) => ({ path: ctx.cwd, format: "markdown", min_severity: "low" }),
  },
  {
    name: "analyze_business_logic",
    category: "Security",
    desc: "Business-logic anti-patterns (current file)",
    timeout: "slow",
    args: pathArg,
  },

  // ── Semantic ───────────────────────────────────────────────────────────
  {
    name: "semantic_operations",
    category: "Semantic",
    desc: "Side-effect profile (DB/HTTP/cache/queue) of the current file",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "semantic_analysis",
    category: "Semantic",
    desc: "Operations + security in one pass (current file)",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "metaast_search",
    category: "Semantic",
    desc: "Cross-language structural pattern search",
    timeout: "default",
    args: async (ctx) => {
      const lang = await ctx.select("Source language:", ["elixir", "erlang", "python", "javascript"]);
      if (!lang) {
        return undefined;
      }
      const construct = await ctx.input("Construct (e.g. Enum.map/2):");
      return construct ? { source_language: lang, source_construct: construct } : undefined;
    },
  },
  {
    name: "find_metaast_pattern",
    category: "Semantic",
    desc: "Find all nodes matching a MetaAST pattern",
    timeout: "default",
    args: async (ctx) => {
      const pattern = await ctx.input("MetaAST pattern (e.g. loop:for):");
      return pattern ? { pattern } : undefined;
    },
  },

  // ── Impact ─────────────────────────────────────────────────────────────
  {
    name: "analyze_impact",
    category: "Impact",
    desc: "Blast radius of changing a target",
    timeout: "default",
    args: targetInput,
  },
  {
    name: "risk_assessment",
    category: "Impact",
    desc: "Risk score for modifying a target",
    timeout: "default",
    args: targetInput,
  },
  {
    name: "estimate_refactoring_effort",
    category: "Impact",
    desc: "Estimate effort for a refactoring operation",
    timeout: "default",
    args: async (ctx) => {
      const op = await ctx.select("Operation:", [
        "rename_function",
        "rename_module",
        "extract_function",
        "inline_function",
        "move_function",
        "change_signature",
      ]);
      if (!op) {
        return undefined;
      }
      const target = await ctx.input("Target (Module.function/arity or Module):");
      return target ? { operation: op, target } : undefined;
    },
  },
  {
    name: "suggest_refactorings",
    category: "Impact",
    desc: "Refactoring opportunities in the current file",
    timeout: "slow",
    args: pathArg,
  },
  {
    name: "visualize_impact",
    category: "Impact",
    desc: "Visualize impact for the current file",
    timeout: "default",
    args: async (ctx) => ({ files: [ctx.path], format: "ascii", depth: 2 }),
  },

  // ── Refactor ───────────────────────────────────────────────────────────
  {
    name: "preview_refactor",
    category: "Refactor",
    desc: "Preview a refactoring (no changes applied)",
    timeout: "default",
    args: async (ctx) => {
      const op = await ctx.select("Operation:", [
        "rename_function",
        "rename_module",
        "extract_function",
        "inline_function",
      ]);
      if (!op) {
        return undefined;
      }
      const module = await ctx.input("Module:");
      if (!module) {
        return undefined;
      }
      const oldName = await ctx.input("Current name:", ctx.word);
      if (!oldName) {
        return undefined;
      }
      const newName = await ctx.input("New name:");
      if (!newName) {
        return undefined;
      }
      return {
        operation: op,
        params: { module, old_name: oldName, new_name: newName },
        format: "unified",
      };
    },
  },
  {
    name: "refactor_conflicts",
    category: "Refactor",
    desc: "Check conflicts before a refactoring",
    timeout: "default",
    args: async (ctx) => {
      const op = await ctx.select("Operation:", [
        "rename_function",
        "rename_module",
        "move_function",
        "extract_module",
      ]);
      if (!op) {
        return undefined;
      }
      const module = await ctx.input("Module:");
      if (!module) {
        return undefined;
      }
      const oldName = await ctx.input("Current name:", ctx.word);
      if (!oldName) {
        return undefined;
      }
      const newName = await ctx.input("New name:");
      if (!newName) {
        return undefined;
      }
      return { operation: op, params: { module, old_name: oldName, new_name: newName } };
    },
  },
  {
    name: "undo_refactor",
    category: "Refactor",
    desc: "Undo the most recent refactoring",
    timeout: "default",
    args: async (ctx) => ({ project_path: ctx.cwd }),
  },
  {
    name: "refactor_history",
    category: "Refactor",
    desc: "List refactoring history",
    timeout: "default",
    args: async (ctx) => ({ project_path: ctx.cwd, limit: 50 }),
  },
  {
    name: "edit_history",
    category: "Refactor",
    desc: "Backup history for the current file",
    timeout: "fast",
    args: pathArg,
  },
  {
    name: "rollback_edit",
    category: "Refactor",
    desc: "Restore the current file from its latest backup",
    timeout: "default",
    args: pathArg,
  },

  // ── RAG / AI ───────────────────────────────────────────────────────────
  {
    name: "rag_query",
    category: "RAG",
    desc: "Ask a question about the codebase (AI answer)",
    timeout: "slow",
    args: async (ctx) => {
      const q = await ctx.input("Question:", ctx.word);
      return q ? { query: q, limit: 12, include_code: true } : undefined;
    },
  },
  {
    name: "rag_explain",
    category: "RAG",
    desc: "AI explanation of a target",
    timeout: "slow",
    args: async (ctx) => {
      const target = await ctx.input("Target (file or Module.function/arity):", ctx.relpath);
      return target ? { target, aspect: "all" } : undefined;
    },
  },
  {
    name: "rag_suggest",
    category: "RAG",
    desc: "AI improvement suggestions for a target",
    timeout: "slow",
    args: async (ctx) => {
      const target = await ctx.input("Target (file or Module.function/arity):", ctx.relpath);
      return target ? { target, focus: "all" } : undefined;
    },
  },
  {
    name: "get_ai_usage",
    category: "RAG",
    desc: "AI provider usage / cost statistics",
    timeout: "fast",
    args: async () => ({}),
  },
  {
    name: "get_ai_cache_stats",
    category: "RAG",
    desc: "AI response cache statistics",
    timeout: "fast",
    args: async () => ({}),
  },
  {
    name: "clear_ai_cache",
    category: "RAG",
    desc: "Clear the AI response cache",
    timeout: "fast",
    args: async () => ({ operation: "all" }),
  },

  // ── Agent ──────────────────────────────────────────────────────────────
  {
    name: "agent_analyze",
    category: "Agent",
    desc: "Full multi-pass AI project analysis",
    timeout: "very_slow",
    args: dirArg,
  },
  {
    name: "agent_list_sessions",
    category: "Agent",
    desc: "List active agent sessions",
    timeout: "fast",
    args: async () => ({}),
  },
  {
    name: "mcp_stats",
    category: "Agent",
    desc: "MCP tool usage telemetry",
    timeout: "fast",
    args: async () => ({}),
  },

  // ── Git ────────────────────────────────────────────────────────────────
  {
    name: "git_blame",
    category: "Git",
    desc: "Git blame for the current file",
    timeout: "default",
    args: pathArg,
  },
  {
    name: "git_history",
    category: "Git",
    desc: "Commit history for the current file",
    timeout: "default",
    args: pathArg,
  },
  {
    name: "co_change_analysis",
    category: "Git",
    desc: "Files that change together with the current file",
    timeout: "default",
    args: pathArg,
  },
  {
    name: "git_enrich",
    category: "Git",
    desc: "Enrich the graph with git metadata",
    timeout: "slow",
    args: dirArg,
  },

  // ── SCIP ───────────────────────────────────────────────────────────────
  {
    name: "scip_status",
    category: "SCIP",
    desc: "SCIP bridge status / available indexers",
    timeout: "fast",
    args: async (ctx) => ({ path: ctx.cwd }),
  },
  {
    name: "scip_index",
    category: "SCIP",
    desc: "Run a SCIP indexer for the project",
    timeout: "very_slow",
    args: async (ctx) => {
      const lang = await ctx.input("Language (blank = auto):");
      if (lang === undefined) {
        return undefined;
      }
      return lang === "" ? { path: ctx.cwd } : { path: ctx.cwd, language: lang };
    },
  },
];

/** Look up a tool spec by name. */
export function getTool(name: string): ToolSpec | undefined {
  return TOOLS.find((t) => t.name === name);
}

/** Group tools by category, preserving declaration order. */
export function toolsByCategory(): Map<string, ToolSpec[]> {
  const map = new Map<string, ToolSpec[]>();
  for (const tool of TOOLS) {
    const list = map.get(tool.category) ?? [];
    list.push(tool);
    map.set(tool.category, list);
  }
  return map;
}

/** Build a `vscode.QuickPickItem` list for the tool menu. */
export function toQuickPickItems(tools: ToolSpec[]): vscode.QuickPickItem[] {
  return tools.map((t) => ({
    label: t.name,
    description: t.category,
    detail: t.desc,
  }));
}
