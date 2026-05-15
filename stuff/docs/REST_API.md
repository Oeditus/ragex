# REST API Bridge

Phase K exposes all Ragex MCP tools over HTTP via a lightweight Bandit server.
This enables non-MCP integrations: CI pipelines, dashboards, scripts, and
any HTTP-aware tooling.

## Quick Start

```bash
# Start the server (default port 4321)
mix ragex.serve

# Custom port
mix ragex.serve --port 8080
```

## Endpoints

### `GET /api/health`

Health check returning server status and graph stats.

```bash
curl http://localhost:4321/api/health
```

```json
{"status": "ok", "version": "0.14.1", "graph": {"nodes": 42, "edges": 87, "embeddings": 42}}
```

### `GET /api/tools`

List all available MCP tools with their descriptions and schemas.

```bash
curl http://localhost:4321/api/tools
```

### `GET /api/openapi.json`

Auto-generated OpenAPI 3.0 specification. Import into Swagger UI, Postman,
or any OpenAPI-compatible tool.

```bash
curl http://localhost:4321/api/openapi.json
```

### `POST /api/tools/:tool_name`

Invoke any MCP tool. The request body is the tool's arguments as JSON.

```bash
# Analyze a file
curl -X POST http://localhost:4321/api/tools/analyze_file \
  -H "Content-Type: application/json" \
  -d '{"path": "lib/my_module.ex"}'

# Search strings
curl -X POST http://localhost:4321/api/tools/search_strings \
  -H "Content-Type: application/json" \
  -d '{"query": "INSERT INTO", "limit": 10}'

# Graph stats
curl -X POST http://localhost:4321/api/tools/graph_stats \
  -H "Content-Type: application/json" \
  -d '{}'
```

## Authentication

Set the `RAGEX_API_KEY` environment variable to require authentication:

```bash
RAGEX_API_KEY=my-secret-key mix ragex.serve
```

Then include the key in requests:

```bash
curl -H "Authorization: Bearer my-secret-key" \
  http://localhost:4321/api/tools
```

When `RAGEX_API_KEY` is not set, all requests pass through without authentication.

## Configuration

In `config/config.exs`:

```elixir
config :ragex,
  # Auto-start API server with the application
  start_api: true,
  # Custom port (default: 4321)
  api_port: 4321
```

Or start programmatically:

```elixir
Ragex.API.Server.start_link(port: 8080)
```

## Architecture

- **`Ragex.API.Router`** -- Plug.Router with all endpoints
- **`Ragex.API.Auth`** -- Optional bearer token authentication plug
- **`Ragex.API.OpenAPI`** -- OpenAPI 3.0 spec generator (lazy, cached)
- **`Ragex.API.Server`** -- Bandit wrapper with child_spec for supervision

The router delegates tool calls to the same `Tools.call_tool/2` used by
the MCP server, ensuring identical behavior between MCP and HTTP.

## Error Handling

- **200** -- successful tool invocation
- **401** -- missing or invalid API key (when `RAGEX_API_KEY` is set)
- **404** -- unknown route
- **422** -- tool execution error (invalid params, analysis failure, etc.)
- **500** -- unexpected server error

Error responses always include an `error` field with a description.
