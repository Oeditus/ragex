import { ChildProcess, spawn } from "child_process";
import * as fs from "fs";
import * as net from "net";
import * as vscode from "vscode";
import { computeSocketPath } from "./socketPath";

export type TransportKind = "socket" | "stdio";

export interface RagexError {
  kind: string;
  message: string;
  code?: number;
}

export interface RpcMessage {
  jsonrpc: "2.0";
  id?: number | string;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code?: number; message?: string };
}

export interface RequestOptions {
  /** Called with each streamed progress chunk (streaming tools only). */
  onChunk?: (text: string, done: boolean, value: unknown) => void;
  /** Per-request timeout in milliseconds. */
  timeout?: number;
}

interface PendingEntry {
  resolve: (value: unknown) => void;
  reject: (err: RagexError) => void;
  timer?: NodeJS.Timeout;
  onChunk?: (text: string, done: boolean, value: unknown) => void;
}

/**
 * JSON-RPC 2.0 client for the Ragex MCP server.
 *
 * Supports two transports behind one API:
 *   - **socket** -- a Unix domain socket exposed by a running Ragex server.
 *     Preferred, because it reuses the already-warm VM (graph, embeddings).
 *   - **stdio** -- spawns `bin/ragex-mcp` and speaks newline-delimited
 *     JSON-RPC over its stdin/stdout, exactly like Zed / Cursor / Claude.
 *
 * The default mode is `auto`: reuse a live socket when one is present,
 * otherwise launch a stdio child. Connections are health-checked and
 * re-established lazily on the next request after a failure.
 */
export class RagexClient implements vscode.Disposable {
  private kind: TransportKind | null = null;
  private socket: net.Socket | null = null;
  private child: ChildProcess | null = null;
  private nextId = 1;
  private pending = new Map<string, PendingEntry>();
  private buffer = "";
  private ready = false;
  private starting: Promise<void> | null = null;
  private disposed = false;

  constructor(
    private readonly log: (msg: string) => void,
    private readonly config: () => ClientConfig
  ) {}

  /** True when a transport is currently established. */
  get isConnected(): boolean {
    return this.ready;
  }

  get transportKind(): TransportKind | null {
    return this.kind;
  }

  /** Send a JSON-RPC request and await its result. */
  async request(method: string, params?: unknown, opts: RequestOptions = {}): Promise<unknown> {
    if (this.disposed) {
      throw { kind: "disposed", message: "client disposed" } as RagexError;
    }

    await this.ensureConnected();

    const id = this.nextId++;
    const key = String(id);
    const message: RpcMessage = { jsonrpc: "2.0", id, method, params: params ?? {} };
    const timeout = opts.timeout ?? this.config().requestTimeout;

    return new Promise<unknown>((resolve, reject) => {
      const entry: PendingEntry = { resolve, reject, onChunk: opts.onChunk };

      if (timeout > 0) {
        entry.timer = setTimeout(() => {
          if (this.pending.delete(key)) {
            reject({ kind: "timeout", message: `request timed out after ${timeout}ms` });
          }
        }, timeout);
      }

      this.pending.set(key, entry);
      this.send(JSON.stringify(message) + "\n").catch((err) => {
        const pending = this.pending.get(key);
        if (pending) {
          this.pending.delete(key);
          if (pending.timer) {
            clearTimeout(pending.timer);
          }
          reject({ kind: "send", message: String(err) });
        }
      });
    });
  }

  /** Call an MCP tool (`tools/call`). */
  callTool(name: string, args: Record<string, unknown> = {}, opts: RequestOptions = {}): Promise<unknown> {
    return this.request("tools/call", { name, arguments: args }, opts);
  }

  /** List available tools. */
  listTools(): Promise<unknown> {
    return this.request("tools/list", {});
  }

  /** List resources. */
  listResources(): Promise<unknown> {
    return this.request("resources/list", {});
  }

  /** Read a resource by URI. */
  readResource(uri: string): Promise<unknown> {
    return this.request("resources/read", { uri });
  }

  /** List prompts. */
  listPrompts(): Promise<unknown> {
    return this.request("prompts/list", {});
  }

  /** Close the transport and reject outstanding requests. */
  close(): void {
    this.failAll("connection closed");
    this.teardown();
  }

  dispose(): void {
    this.disposed = true;
    this.close();
  }

  // ── Connection lifecycle ────────────────────────────────────────────────

  private teardown(): void {
    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
      this.socket = null;
    }
    if (this.child) {
      this.child.removeAllListeners();
      try {
        this.child.kill();
      } catch {
        /* ignore */
      }
      this.child = null;
    }
    this.kind = null;
    this.ready = false;
    this.buffer = "";
  }

  private failAll(reason: string): void {
    const entries = Array.from(this.pending.values());
    this.pending.clear();
    for (const entry of entries) {
      if (entry.timer) {
        clearTimeout(entry.timer);
      }
      entry.reject({ kind: "transport", message: reason });
    }
  }

  private ensureConnected(): Promise<void> {
    if (this.ready) {
      return Promise.resolve();
    }
    if (this.starting) {
      return this.starting;
    }

    this.starting = this.connect().finally(() => {
      this.starting = null;
    });
    return this.starting;
  }

  private async connect(): Promise<void> {
    const cfg = this.config();
    const socketPath = cfg.socketPath ?? computeSocketPath(cfg.projectRoot);

    const wantSocket = cfg.transport === "socket" || (cfg.transport === "auto" && fs.existsSync(socketPath));

    if (wantSocket) {
      try {
        await this.connectSocket(socketPath);
        this.log(`connected via socket ${socketPath}`);
        return;
      } catch (err) {
        this.log(`socket connection failed: ${String(err)}`);
        if (cfg.transport === "socket") {
          throw { kind: "socket", message: `could not connect to ${socketPath}` } as RagexError;
        }
      }
    }

    await this.connectStdio();
    this.log("connected via stdio child");
  }

  private connectSocket(socketPath: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const socket = net.createConnection(socketPath);

      const onError = (err: Error) => {
        socket.destroy();
        reject(err);
      };

      socket.once("error", onError);
      socket.once("connect", () => {
        socket.removeListener("error", onError);
        socket.on("error", (err) => this.log(`socket error: ${err.message}`));
        socket.on("close", () => {
          this.log("socket closed");
          this.teardown();
          this.failAll("socket closed");
        });
        socket.on("data", (data: Buffer) => this.handleData(data.toString("utf8")));

        this.socket = socket;
        this.kind = "socket";
        this.ready = true;
        resolve();
      });
    });
  }

  private connectStdio(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const cfg = this.config();
      const bin = cfg.binPath;
      if (!bin || !fs.existsSync(bin)) {
        reject({ kind: "config", message: `ragex-mcp binary not found: ${bin || "(unset)"}` } as RagexError);
        return;
      }

      const args: string[] = [];
      if (cfg.projectRoot) {
        args.push("--project", cfg.projectRoot);
      }
      if (cfg.logLevel) {
        args.push("--log-level", cfg.logLevel);
      }

      this.log(`spawning stdio child: ${bin} ${args.join(" ")}`);

      let child: ChildProcess;
      try {
        child = spawn(bin, args, { stdio: ["pipe", "pipe", "pipe"] });
      } catch (err) {
        reject({ kind: "spawn", message: String(err) } as RagexError);
        return;
      }

      let settled = false;

      child.once("error", (err) => {
        if (!settled) {
          settled = true;
          reject({ kind: "spawn", message: err.message } as RagexError);
        }
      });

      child.on("exit", (code) => {
        this.log(`stdio child exited with code ${code}`);
        this.teardown();
        this.failAll(`ragex-mcp exited (code ${code})`);
      });

      child.stdout?.on("data", (data: Buffer) => this.handleData(data.toString("utf8")));
      child.stderr?.on("data", (data: Buffer) => {
        const text = data.toString("utf8").trim();
        if (text) {
          this.log(`stderr: ${text}`);
        }
      });

      this.child = child;
      this.kind = "stdio";
      this.ready = true;
      settled = true;
      resolve();
    });
  }

  private send(payload: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.kind === "socket" && this.socket) {
        this.socket.write(payload, (err) => (err ? reject(err) : resolve()));
      } else if (this.kind === "stdio" && this.child?.stdin) {
        this.child.stdin.write(payload, (err) => (err ? reject(err) : resolve()));
      } else {
        reject(new Error("no active transport"));
      }
    });
  }

  // ── Message dispatch ────────────────────────────────────────────────────

  private handleData(chunk: string): void {
    this.buffer += chunk;

    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (line) {
        this.dispatch(line);
      }
    }
  }

  private dispatch(line: string): void {
    let msg: RpcMessage;
    try {
      msg = JSON.parse(line) as RpcMessage;
    } catch {
      this.log(`dropped unparsable message: ${line.slice(0, 200)}`);
      return;
    }

    if (msg.id === undefined || msg.id === null) {
      this.handleNotification(msg);
      return;
    }

    const key = String(msg.id);
    const entry = this.pending.get(key);
    if (!entry) {
      this.handleNotification(msg);
      return;
    }

    this.pending.delete(key);
    if (entry.timer) {
      clearTimeout(entry.timer);
    }

    if (msg.error) {
      entry.reject({ kind: "rpc", message: msg.error.message ?? "unknown error", code: msg.error.code });
    } else {
      entry.resolve(msg.result);
    }
  }

  private handleNotification(msg: RpcMessage): void {
    const method = msg.method ?? "";
    const params = (msg.params ?? {}) as Record<string, unknown>;

    const token = params.progressToken;
    if (token !== undefined && token !== null) {
      const entry = this.pending.get(String(token));
      if (entry?.onChunk) {
        const value = (params.value ?? {}) as Record<string, unknown>;
        entry.onChunk(String(value.text ?? ""), value.done === true, value);
      }
    }

    if (method === "ai/progress") {
      for (const entry of this.pending.values()) {
        if (entry.onChunk) {
          entry.onChunk(String(params.text ?? ""), false, params);
        }
      }
    }
  }
}

export interface ClientConfig {
  transport: "auto" | "socket" | "stdio";
  socketPath?: string;
  binPath: string;
  projectRoot?: string;
  logLevel: string;
  requestTimeout: number;
}
