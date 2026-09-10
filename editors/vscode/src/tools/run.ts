import * as path from "path";
import * as vscode from "vscode";
import { errorMessage, location, searchResults, unwrap } from "../response";
import { RagexClient } from "../transport/client";
import { getTool, TIMEOUTS, ToolContext, ToolSpec } from "./catalog";
import { notify, ResultDocument, StreamPanel } from "../ui/panels";

/**
 * Tool execution: build context, call the tool, display the result.
 *
 * Centralizes the "prompt -> call -> render" flow so every catalog tool and
 * the generic `Ragex: Call Tool…` command share identical behaviour.
 */
export class ToolRunner {
  constructor(private readonly client: RagexClient) {}

  /** Build the context handed to catalog `args` builders. */
  context(): ToolContext {
    const editor = vscode.window.activeTextEditor;
    const filePath = editor?.document.uri.scheme === "file" ? editor.document.uri.fsPath : "";
    const cwd = this.projectRoot();

    let relpath = filePath;
    if (filePath && filePath.startsWith(cwd)) {
      relpath = path.relative(cwd, filePath);
    }

    let word = "";
    if (editor) {
      const range = editor.document.getWordRangeAtPosition(editor.selection.active);
      if (range) {
        word = editor.document.getText(range);
      }
    }

    return {
      path: filePath,
      relpath,
      cwd,
      word,
      input: async (prompt, value) => {
        const result = await vscode.window.showInputBox({ prompt, value });
        return result;
      },
      select: async (prompt, items) => {
        const result = await vscode.window.showQuickPick(items, { placeHolder: prompt });
        return result;
      },
    };
  }

  /** The project root: first workspace folder, else cwd. */
  projectRoot(): string {
    const folders = vscode.workspace.workspaceFolders;
    if (folders && folders.length > 0) {
      return folders[0].uri.fsPath;
    }
    return process.cwd();
  }

  /** Resolve the timeout for a tool spec. */
  private timeoutFor(spec: ToolSpec | undefined): number {
    return TIMEOUTS[spec?.timeout ?? "default"];
  }

  /** Run a tool with explicit arguments and render the result. */
  async run(
    name: string,
    args: Record<string, unknown>,
    opts: { silent?: boolean; render?: (data: unknown) => Promise<void> } = {}
  ): Promise<unknown> {
    const spec = getTool(name);
    const timeout = this.timeoutFor(spec);

    try {
      const result = await this.client.callTool(name, args, { timeout });
      const data = unwrap(result);

      if (opts.render) {
        await opts.render(data);
      } else if (!opts.silent) {
        await this.render(name, data);
      }
      return data;
    } catch (err) {
      notify(`${name} failed: ${errorMessage(err)}`, "error");
      throw err;
    }
  }

  /** Run a catalog tool: build args from context, then execute. */
  async runCatalog(name: string): Promise<void> {
    const spec = getTool(name);
    if (!spec) {
      notify(`unknown tool: ${name}`, "error");
      return;
    }

    const ctx = this.context();
    const args = await spec.args(ctx);
    if (args === undefined) {
      return; // user cancelled a prompt
    }

    await this.run(name, args);
  }

  /** Render a tool payload into the results document. */
  async render(title: string, data: unknown): Promise<void> {
    const body = this.prettify(data);
    await ResultDocument.get().show(title, body);
  }

  /** Choose a human-friendly representation for a payload. */
  private prettify(data: unknown): string {
    if (data && typeof data === "object" && !Array.isArray(data)) {
      const obj = data as Record<string, unknown>;
      for (const key of ["summary", "content", "report", "text", "message"]) {
        const value = obj[key];
        if (typeof value === "string" && value.length > 0) {
          return value;
        }
      }
    }
    try {
      return JSON.stringify(data, null, 2);
    } catch {
      return String(data);
    }
  }

  // ── Specialized flows ───────────────────────────────────────────────────

  /** Run a search tool and present results in a QuickPick. */
  async search(tool: "semantic_search" | "hybrid_search", query?: string, extra: Record<string, unknown> = {}): Promise<void> {
    const ctx = this.context();
    const q = query ?? (await vscode.window.showInputBox({ prompt: "Ragex search:", value: ctx.word }));
    if (!q) {
      return;
    }

    const args = { query: q, limit: 30, include_context: true, ...extra };

    try {
      const result = await this.client.callTool(tool, args, { timeout: TIMEOUTS.default });
      const data = unwrap(result);
      const results = searchResults(data);

      if (results.length === 0) {
        notify("no results", "warn");
        return;
      }

      const items: (vscode.QuickPickItem & { result: (typeof results)[number] })[] = results.map((r) => ({
        label: r.node_id ?? "?",
        description: typeof r.score === "number" ? r.score.toFixed(3) : undefined,
        detail: [r.context?.file, r.description].filter(Boolean).join("  —  "),
        result: r,
      }));

      const picked = await vscode.window.showQuickPick(items, {
        placeHolder: `${results.length} result(s)`,
        matchOnDetail: true,
      });

      if (picked) {
        await this.openResult(picked.result);
      }
    } catch (err) {
      notify(`search failed: ${errorMessage(err)}`, "error");
    }
  }

  /** Open a search result at its file:line. */
  private async openResult(item: ReturnType<typeof searchResults>[number]): Promise<void> {
    const { file, line } = location(item);
    if (!file) {
      await this.render("result", item);
      return;
    }

    const uri = vscode.Uri.file(path.isAbsolute(file) ? file : path.join(this.projectRoot(), file));
    const doc = await vscode.workspace.openTextDocument(uri);
    const editor = await vscode.window.showTextDocument(doc);
    if (line && line > 0) {
      const pos = new vscode.Position(Math.max(0, line - 1), 0);
      editor.selection = new vscode.Selection(pos, pos);
      editor.revealRange(new vscode.Range(pos, pos), vscode.TextEditorRevealType.InCenter);
    }
  }

  /** Stream a RAG tool into a live panel. */
  async stream(tool: "rag_query" | "rag_explain" | "rag_suggest", args: Record<string, unknown>): Promise<void> {
    const streamTool = `${tool}_stream`;
    const panel = StreamPanel.get();
    await panel.start(`Ragex ${tool}`);

    let received = false;

    try {
      const result = await this.client.callTool(streamTool, args, {
        timeout: TIMEOUTS.very_slow,
        onChunk: (text) => {
          if (text) {
            received = true;
            panel.append(text);
          }
        },
      });

      const data = unwrap(result) as Record<string, unknown> | undefined;

      if (!received && data) {
        const text = (data.response as string) ?? (data.explanation as string) ?? (data.suggestions as string);
        if (typeof text === "string" && text.length > 0) {
          panel.append(text);
        } else {
          panel.append("```json\n" + JSON.stringify(data, null, 2) + "\n```");
        }
      }

      panel.finish();
      notify(`${tool} complete`);
    } catch (err) {
      panel.append(`\n\n**Error:** ${errorMessage(err)}\n`);
      panel.finish();
      notify(`${tool} failed: ${errorMessage(err)}`, "error");
    }
  }

  /** Rename a function project-wide. */
  async renameFunction(): Promise<void> {
    const ctx = this.context();
    const module = await vscode.window.showInputBox({ prompt: "Module:" });
    if (!module) {
      return;
    }
    const oldName = await vscode.window.showInputBox({ prompt: "Current function name:", value: ctx.word });
    if (!oldName) {
      return;
    }
    const newName = await vscode.window.showInputBox({ prompt: "New function name:" });
    if (!newName) {
      return;
    }
    const arity = await vscode.window.showInputBox({ prompt: "Arity (blank = any):" });

    const params: Record<string, unknown> = { module, old_name: oldName, new_name: newName };
    if (arity && arity.trim() !== "") {
      params.arity = Number(arity);
    }

    const confirm = await vscode.window.showWarningMessage(
      `Rename ${module}.${oldName} → ${newName} project-wide?`,
      { modal: true },
      "Rename"
    );
    if (confirm !== "Rename") {
      return;
    }

    await this.run("refactor_code", {
      operation: "rename_function",
      params,
      scope: "project",
      validate: true,
      format: true,
    });
  }

  /** Rename a module project-wide. */
  async renameModule(): Promise<void> {
    const oldName = await vscode.window.showInputBox({ prompt: "Current module name:" });
    if (!oldName) {
      return;
    }
    const newName = await vscode.window.showInputBox({ prompt: "New module name:" });
    if (!newName) {
      return;
    }

    const confirm = await vscode.window.showWarningMessage(
      `Rename module ${oldName} → ${newName} project-wide?`,
      { modal: true },
      "Rename"
    );
    if (confirm !== "Rename") {
      return;
    }

    await this.run("refactor_code", {
      operation: "rename_module",
      params: { old_name: oldName, new_name: newName },
      validate: true,
    });
  }
}
