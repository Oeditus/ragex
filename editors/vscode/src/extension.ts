import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { computeSocketPath } from "./transport/socketPath";
import { ClientConfig, RagexClient } from "./transport/client";
import { getTool, toolsByCategory, toQuickPickItems, TOOLS } from "./tools/catalog";
import { ToolRunner } from "./tools/run";
import { channel, log, notify, ResultDocument } from "./ui/panels";

let client: RagexClient | undefined;
let runner: ToolRunner | undefined;

/**
 * Extension entry point.
 *
 * Wires up the transport, the tool runner, every contributed command, and the
 * optional auto-analyze / analyze-on-startup behaviours.
 */
export function activate(context: vscode.ExtensionContext): void {
  const cfg = () => readConfig();

  client = new RagexClient((msg) => {
    if (vscode.workspace.getConfiguration("ragex").get<boolean>("debug", false)) {
      log(msg);
    }
  }, cfg);

  runner = new ToolRunner(client);

  const resultDoc = ResultDocument.get();

  context.subscriptions.push(
    resultDoc,
    client,
    channel(),
    vscode.commands.registerCommand("ragex.toolMenu", () => toolMenu()),
    vscode.commands.registerCommand("ragex.status", () => showStatus()),
    vscode.commands.registerCommand("ragex.restart", () => restart()),
    vscode.commands.registerCommand("ragex.hybridSearch", () => runner!.search("hybrid_search")),
    vscode.commands.registerCommand("ragex.semanticSearch", () => runner!.search("semantic_search")),
    vscode.commands.registerCommand("ragex.searchWord", () => {
      const word = runner!.context().word;
      if (!word) {
        notify("no word under cursor", "warn");
        return;
      }
      return runner!.search("hybrid_search", word);
    }),
    vscode.commands.registerCommand("ragex.analyzeFile", () => runTool("analyze_file")),
    vscode.commands.registerCommand("ragex.analyzeDirectory", () => runTool("analyze_directory")),
    vscode.commands.registerCommand("ragex.ragQuery", () => {
      void vscode.window
        .showInputBox({ prompt: "Ragex question:", value: runner!.context().word })
        .then((q) => {
          if (q) {
            return runner!.stream("rag_query", { query: q, limit: 12, include_code: true });
          }
          return undefined;
        });
    }),
    vscode.commands.registerCommand("ragex.ragExplain", () => {
      const target = runner!.context().relpath;
      if (!target) {
        notify("no active file", "warn");
        return;
      }
      return runner!.stream("rag_explain", { target, aspect: "all" });
    }),
    vscode.commands.registerCommand("ragex.ragSuggest", () => {
      const target = runner!.context().relpath;
      if (!target) {
        notify("no active file", "warn");
        return;
      }
      return runner!.stream("rag_suggest", { target, focus: "all" });
    }),
    vscode.commands.registerCommand("ragex.renameFunction", () => runner!.renameFunction()),
    vscode.commands.registerCommand("ragex.renameModule", () => runner!.renameModule()),
    vscode.commands.registerCommand("ragex.findCallers", () => runTool("find_callers")),
    vscode.commands.registerCommand("ragex.graphStats", () => runTool("graph_stats")),
    vscode.commands.registerCommand("ragex.watchDirectory", () => runTool("watch_directory")),
    vscode.commands.registerCommand("ragex.callTool", () => callToolPicker()),
    vscode.workspace.onDidSaveTextDocument((doc) => onSave(doc))
  );

  if (vscode.workspace.getConfiguration("ragex").get<boolean>("analyzeOnStartup", true)) {
    void runTool("analyze_directory");
  }

  log("Ragex extension activated");
}

export function deactivate(): void {
  client?.dispose();
  client = undefined;
  runner = undefined;
}

// ── Helpers ───────────────────────────────────────────────────────────────

/** Read the extension configuration into a transport config. */
function readConfig(): ClientConfig {
  const cfg = vscode.workspace.getConfiguration("ragex");
  const projectRoot = cfg.get<string>("projectRoot") || firstWorkspaceFolder();

  return {
    transport: cfg.get<"auto" | "socket" | "stdio">("transport", "auto"),
    socketPath: cfg.get<string>("socketPath") || undefined,
    binPath: resolveBin(cfg.get<string>("binPath") || "", projectRoot),
    projectRoot,
    logLevel: cfg.get<string>("logLevel", "info"),
    requestTimeout: 60000,
  };
}

function firstWorkspaceFolder(): string {
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length > 0 ? folders[0].uri.fsPath : process.cwd();
}

/** Resolve the ragex-mcp binary: explicit path, else walk up from the root. */
function resolveBin(explicit: string, projectRoot: string): string {
  if (explicit && fs.existsSync(explicit)) {
    return explicit;
  }

  let dir = projectRoot;
  for (let i = 0; i < 12; i++) {
    const candidate = path.join(dir, "bin", "ragex-mcp");
    if (fs.existsSync(candidate)) {
      return candidate;
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }

  return explicit;
}

/** Run a catalog tool by name. */
async function runTool(name: string): Promise<void> {
  if (!runner) {
    return;
  }
  try {
    await runner.runCatalog(name);
  } catch {
    /* already notified */
  }
}

/** Interactive tool picker (category -> tool). */
async function toolMenu(): Promise<void> {
  const categories = Array.from(toolsByCategory().keys());
  const category = await vscode.window.showQuickPick(categories, { placeHolder: "Ragex category" });
  if (!category) {
    return;
  }

  const tools = toolsByCategory().get(category) ?? [];
  const picked = await vscode.window.showQuickPick(toQuickPickItems(tools), {
    placeHolder: `Ragex tools — ${category}`,
    matchOnDetail: true,
  });
  if (!picked) {
    return;
  }

  await runTool(picked.label);
}

/** Generic "call any tool with key=value args" picker. */
async function callToolPicker(): Promise<void> {
  const picked = await vscode.window.showQuickPick(toQuickPickItems(TOOLS), {
    placeHolder: "Ragex: pick a tool",
    matchOnDetail: true,
  });
  if (!picked) {
    return;
  }

  const spec = getTool(picked.label);
  if (!spec) {
    return;
  }

  const raw = await vscode.window.showInputBox({
    prompt: `Arguments for ${spec.name} as JSON (blank = {}):`,
    value: "{}",
    validateInput: (value) => {
      if (!value || value.trim() === "") {
        return undefined;
      }
      try {
        JSON.parse(value);
        return undefined;
      } catch (err) {
        return `Invalid JSON: ${String(err)}`;
      }
    },
  });
  if (raw === undefined) {
    return;
  }

  let args: Record<string, unknown> = {};
  if (raw.trim() !== "") {
    try {
      args = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      notify("invalid JSON arguments", "error");
      return;
    }
  }

  await runner!.run(spec.name, args);
}

/** Show a connection + graph summary. */
async function showStatus(): Promise<void> {
  if (!client || !runner) {
    return;
  }

  const cfg = readConfig();
  const socketPath = cfg.socketPath ?? computeSocketPath(cfg.projectRoot);

  try {
    const result = await client.callTool("graph_stats", {}, { timeout: 10000 });
    const data = (await import("./response")).unwrap(result) as Record<string, unknown> | undefined;

    const lines = [
      "# Ragex status",
      "",
      `- transport: ${client.transportKind ?? "(disconnected)"}`,
      `- socket: \`${socketPath}\``,
      `- binary: \`${cfg.binPath || "(unset)"}\``,
      `- project: \`${cfg.projectRoot ?? "(unset)"}\``,
      "",
      `- graph nodes: ${data?.node_count ?? "?"}`,
      `- graph edges: ${data?.edge_count ?? "?"}`,
    ];
    await ResultDocument.get().show("status", lines.join("\n"), "markdown");
  } catch (err) {
    notify(`not connected: ${(await import("./response")).errorMessage(err)}`, "warn");
  }
}

/** Tear down and reconnect on the next request. */
async function restart(): Promise<void> {
  client?.close();
  notify("connection reset");
}

/** Re-index the saved file when auto-analyze is enabled. */
function onSave(doc: vscode.TextDocument): void {
  const enabled = vscode.workspace.getConfiguration("ragex").get<boolean>("autoAnalyzeOnSave", false);
  if (!enabled || doc.uri.scheme !== "file") {
    return;
  }

  const supported = [".ex", ".exs", ".erl", ".hrl", ".py", ".js", ".jsx", ".ts", ".tsx"];
  if (!supported.some((ext) => doc.fileName.endsWith(ext))) {
    return;
  }

  void client?.callTool("analyze_file", { path: doc.uri.fsPath }, { timeout: 60000 }).catch((err) => {
    log(`auto-analyze failed: ${String(err)}`);
  });
}
