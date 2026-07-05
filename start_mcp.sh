#!/bin/bash

# Production MCP server startup script
# Ensures stdout is clean for JSON-RPC protocol

# Compile first (errors go to stderr)
mix compile 2>&1 >/dev/null

# Run server with clean stdout
# All logs go to stderr by default (configured in config.exs)
exec mix run --no-halt --no-compile
