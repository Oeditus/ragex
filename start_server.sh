#!/usr/bin/env bash
# Start Ragex MCP Server
# This script starts the Ragex application which includes the MCP socket server

set -e

cd "$(dirname "$0")"

# Resolve the MCP socket path (must match Ragex.MCP.SocketPath.compute_string/0):
#   1. RAGEX_MCP_SOCK (explicit override, used verbatim)
#   2. DLLB_PORT      (namespace by dllb server port)
#   3. otherwise       namespace by the current directory (sanitized)
if [[ -n "${RAGEX_MCP_SOCK:-}" ]]; then
  SOCKET_PATH="$RAGEX_MCP_SOCK"
elif [[ -n "${DLLB_PORT:-}" ]]; then
  SOCKET_PATH="/tmp/ragex_mcp_${DLLB_PORT}.sock"
else
  SANITIZED=$(pwd | sed -e 's#^/##' -e 's#[^A-Za-z0-9]#_#g' -e 's#_*$##')
  SOCKET_PATH="/tmp/ragex_mcp_${SANITIZED}.sock"
fi
export RAGEX_MCP_SOCK="$SOCKET_PATH"

echo "════════════════════════════════════════════════════════"
echo "  Starting Ragex MCP Server"
echo "════════════════════════════════════════════════════════"
echo ""
echo "Socket path: $SOCKET_PATH"
echo "Log file: /tmp/ragex_server.log"
echo ""
echo "Press Ctrl+C to stop the server"
echo "════════════════════════════════════════════════════════"
echo ""

# Remove old socket file if it exists
rm -f "$SOCKET_PATH"

# Start the server
# Use --no-halt to keep it running
# Redirect output to log file
exec mix run --no-halt 2>&1 | tee /tmp/ragex_server.log
