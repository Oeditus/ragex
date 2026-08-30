#!/usr/bin/env bash
# Test Ragex MCP socket communication

# Resolve the socket path the same way start_server.sh / bin/ragex-mcp do:
#   1. Explicit override: pass as $1, or set RAGEX_MCP_SOCK
#   2. DLLB_PORT (namespace by dllb server port)
#   3. otherwise namespace by the current directory (sanitized)
if [[ -n "${1:-}" ]]; then
  SOCKET_PATH="$1"
elif [[ -n "${RAGEX_MCP_SOCK:-}" ]]; then
  SOCKET_PATH="$RAGEX_MCP_SOCK"
elif [[ -n "${DLLB_PORT:-}" ]]; then
  SOCKET_PATH="/tmp/ragex_mcp_${DLLB_PORT}.sock"
else
  SANITIZED=$(pwd | sed -e 's#^/##' -e 's#[^A-Za-z0-9]#_#g' -e 's#_*$##')
  SOCKET_PATH="/tmp/ragex_mcp_${SANITIZED}.sock"
fi

echo "Testing Ragex MCP Socket..."
echo ""

# Check if socket exists
if [ ! -S "$SOCKET_PATH" ]; then
    echo "❌ Socket file does not exist: $SOCKET_PATH"
    echo ""
    echo "Other sockets found: $(ls /tmp/ragex_mcp_*.sock 2>/dev/null | tr '\n' ' ')"
    echo "Start the server with: ./start_server.sh"
    exit 1
fi

echo "✓ Socket file exists"
echo ""

# Test if server is listening
echo "Testing if server is responding..."
echo ""

REQUEST='{"jsonrpc":"2.0","method":"tools/call","params":{"name":"graph_stats","arguments":{}},"id":1}'

echo "Sending request:"
echo "$REQUEST"
echo ""

RESPONSE=$(printf '%s\n' "$REQUEST" | socat - UNIX-CONNECT:"$SOCKET_PATH" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "❌ Connection failed (exit code: $EXIT_CODE)"
    echo "Error: $RESPONSE"
    echo ""
    echo "The socket file exists but no process is listening."
    echo "This usually means:"
    echo "  1. The server crashed or was killed"
    echo "  2. The server is stuck in BREAK mode"
    echo "  3. The socket is a leftover from a previous session"
    echo ""
    echo "Solution:"
    echo "  1. Kill any existing server: pkill -f 'mix run'"
    echo "  2. Remove socket: rm -f $SOCKET_PATH"
    echo "  3. Start server: ./start_server.sh"
    exit 1
fi

echo "✓ Server responded"
echo ""
echo "Response:"
echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "✓ Socket communication is working!"
echo "════════════════════════════════════════════════════════"
