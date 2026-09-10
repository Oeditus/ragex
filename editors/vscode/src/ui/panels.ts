import * as vscode from "vscode";

/**
 * Presentation helpers: a shared output channel, a results virtual document,
 * and a streaming panel for RAG answers.
 */

let outputChannel: vscode.OutputChannel | undefined;

/** The shared Ragex output channel (created lazily). */
export function channel(): vscode.OutputChannel {
  if (!outputChannel) {
    outputChannel = vscode.window.createOutputChannel("Ragex");
  }
  return outputChannel;
}

/** Log a line to the Ragex output channel. */
export function log(message: string): void {
  channel().appendLine(`[${new Date().toISOString()}] ${message}`);
}

/** Notify the user with a consistent prefix. */
export function notify(message: string, level: vscode.MessageItem["title"] extends never ? never : "info" | "warn" | "error" = "info"): void {
  const prefixed = `Ragex: ${message}`;
  switch (level) {
    case "error":
      void vscode.window.showErrorMessage(prefixed);
      break;
    case "warn":
      void vscode.window.showWarningMessage(prefixed);
      break;
    default:
      void vscode.window.showInformationMessage(prefixed);
  }
}

/**
 * A virtual, read-only document used to render tool output. Reusing a single
 * URI means repeated calls replace the previous result rather than piling up
 * untitled buffers.
 */
export class ResultDocument implements vscode.TextDocumentContentProvider, vscode.Disposable {
  static readonly scheme = "ragex-result";
  private static instance: ResultDocument | undefined;

  private readonly emitter = new vscode.EventEmitter<vscode.Uri>();
  private contents = new Map<string, string>();
  private readonly registration: vscode.Disposable;

  readonly onDidChange = this.emitter.event;

  private constructor() {
    this.registration = vscode.workspace.registerTextDocumentContentProvider(ResultDocument.scheme, this);
  }

  static get(): ResultDocument {
    if (!ResultDocument.instance) {
      ResultDocument.instance = new ResultDocument();
    }
    return ResultDocument.instance;
  }

  provideTextDocumentContent(uri: vscode.Uri): string {
    return this.contents.get(uri.toString()) ?? "";
  }

  /** Render `body` under `title` and open (or reveal) the results document. */
  async show(title: string, body: string, language = "json"): Promise<void> {
    const slug = title.replace(/[^a-zA-Z0-9]+/g, "-").replace(/^-|-$/g, "");
    const uri = vscode.Uri.parse(`${ResultDocument.scheme}://ragex/${slug}.${language}`);
    this.contents.set(uri.toString(), body);
    this.emitter.fire(uri);

    const doc = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(doc, { preview: true, preserveFocus: false });
  }

  dispose(): void {
    this.registration.dispose();
    this.emitter.dispose();
  }
}

/**
 * A streaming panel for RAG answers. Tokens are appended as they arrive from
 * `notifications/progress`, giving a live "typing" effect.
 */
export class StreamPanel implements vscode.Disposable {
  private static instance: StreamPanel | undefined;

  private readonly emitter = new vscode.EventEmitter<vscode.Uri>();
  private text = "";
  private uri: vscode.Uri;
  private registration: vscode.Disposable;
  private openPromise: Thenable<vscode.TextEditor> | undefined;

  readonly onDidChange = this.emitter.event;

  private constructor() {
    this.uri = vscode.Uri.parse(`${ResultDocument.scheme}://ragex/stream.md`);
    this.registration = vscode.workspace.registerTextDocumentContentProvider(ResultDocument.scheme, {
      provideTextDocumentContent: (u) => (u.toString() === this.uri.toString() ? this.text : ""),
    });
  }

  static get(): StreamPanel {
    if (!StreamPanel.instance) {
      StreamPanel.instance = new StreamPanel();
    }
    return StreamPanel.instance;
  }

  /** Open the panel and reset its contents. */
  async start(header: string): Promise<void> {
    this.text = `# ${header}\n\n`;
    this.emitter.fire(this.uri);
    const doc = await vscode.workspace.openTextDocument(this.uri);
    this.openPromise = vscode.window.showTextDocument(doc, { preview: false, preserveFocus: false });
  }

  /** Append a streamed chunk. */
  append(chunk: string): void {
    if (!chunk) {
      return;
    }
    this.text += chunk;
    this.emitter.fire(this.uri);
    void this.openPromise?.then((editor) => {
      const end = new vscode.Position(editor.document.lineCount, 0);
      editor.selection = new vscode.Selection(end, end);
      editor.revealRange(new vscode.Range(end, end));
    });
  }

  /** Mark the stream as complete. */
  finish(): void {
    this.text += "\n";
    this.emitter.fire(this.uri);
  }

  dispose(): void {
    this.registration.dispose();
    this.emitter.dispose();
    StreamPanel.instance = undefined;
  }
}
