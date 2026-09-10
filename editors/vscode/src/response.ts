import { RagexError } from "./transport/client";

/**
 * Helpers for interpreting Ragex MCP responses.
 *
 * Every `tools/call` response is wrapped by the server as:
 *   { content: [ { type: "text", text: "<json>" } ] }
 * where `<json>` is the JSON-encoded tool payload. These helpers unwrap that
 * envelope and decode the inner payload.
 */

export interface SearchResult {
  node_type?: string;
  node_id?: string;
  score?: number;
  description?: string;
  context?: {
    file?: string;
    line?: number;
    module?: string;
    function?: string;
    arity?: number;
    callers?: number;
    callees?: number;
  };
}

/** Unwrap an MCP `tools/call` result into the decoded tool payload. */
export function unwrap(result: unknown): unknown {
  if (result === null || result === undefined) {
    return undefined;
  }

  const obj = result as Record<string, unknown>;

  if (obj.error) {
    return obj;
  }

  const content = obj.content;
  if (!Array.isArray(content) || content.length === 0) {
    return result;
  }

  const first = content[0] as Record<string, unknown>;
  const text = first?.text;
  if (typeof text !== "string") {
    return result;
  }

  try {
    return JSON.parse(text);
  } catch {
    return { text };
  }
}

/** Normalize a tool error into a human-readable string. */
export function errorMessage(err: unknown): string {
  if (!err) {
    return "unknown error";
  }
  if (typeof err === "string") {
    return err;
  }
  const e = err as RagexError;
  if (e.message) {
    return e.message;
  }
  return JSON.stringify(err);
}

/** Extract the results array from a search payload. */
export function searchResults(data: unknown): SearchResult[] {
  if (!data || typeof data !== "object") {
    return [];
  }
  const results = (data as Record<string, unknown>).results;
  return Array.isArray(results) ? (results as SearchResult[]) : [];
}

/** Render a search result as a single display line. */
export function formatSearchItem(item: SearchResult): string {
  const id = item.node_id ?? "?";
  const score = typeof item.score === "number" ? item.score.toFixed(3) : "?";
  const desc = item.description ?? "";

  let location = "";
  if (item.context?.file) {
    location = item.context.file;
    if (item.context.line) {
      location = `${location}:${item.context.line}`;
    }
  }

  const parts = [`[${score}] ${id}`];
  if (location) {
    parts.push(location);
  }
  if (desc) {
    parts.push(desc);
  }
  return parts.join("  ");
}

/** Extract a file path and line from a search result, if present. */
export function location(item: SearchResult): { file?: string; line?: number } {
  return { file: item.context?.file, line: item.context?.line };
}
