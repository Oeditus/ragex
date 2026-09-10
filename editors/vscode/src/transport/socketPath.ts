import * as os from "os";
import * as path from "path";

/**
 * Resolve the Ragex MCP socket path.
 *
 * This mirrors the precedence implemented in three places that MUST agree:
 *   - `Ragex.MCP.SocketPath.compute_string/0` (Elixir)
 *   - `bin/ragex-mcp` (Bash launcher)
 *   - `editors/nvim/lua/ragex/socket_path.lua` (Lua client)
 *
 *   1. `RAGEX_MCP_SOCK` -- explicit override, used verbatim.
 *   2. `DLLB_PORT`      -- namespace by the dllb server port.
 *   3. otherwise        -- namespace by the project identity (sanitized).
 */
export function computeSocketPath(projectRoot?: string): string {
  const override = env("RAGEX_MCP_SOCK");
  if (override) {
    return override;
  }

  const port = env("DLLB_PORT");
  if (port) {
    return `/tmp/ragex_mcp_${port}.sock`;
  }

  const identity = env("RAGEX_PROJECT") ?? env("RAGEX_AUTO_ANALYZE") ?? projectRoot ?? process.cwd();
  return `/tmp/ragex_mcp_${sanitize(identity)}.sock`;
}

/**
 * Sanitize an absolute path the same way the Elixir implementation does:
 * strip the leading slash, collapse every run of non-alphanumerics to a single
 * underscore, and trim trailing underscores.
 */
export function sanitize(input: string): string {
  const resolved = path.resolve(input);
  return resolved
    .replace(/^\/+/, "")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/_+$/, "");
}

function env(name: string): string | undefined {
  const value = process.env[name];
  return value === undefined || value === "" ? undefined : value;
}

/** The socket directory Ragex uses, exposed for diagnostics. */
export const SOCKET_DIR = os.tmpdir();
