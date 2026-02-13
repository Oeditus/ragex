#!/usr/bin/env bash
# Test Ragex MCP socket communication

echo "Testing Ragex MCP Socket..."
echo ""

# Check if socket exists
if [ ! -S /tmp/ragex_mcp.sock ]; then
    echo "❌ Socket file does not exist: /tmp/ragex_mcp.sock"
    echo ""
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

RESPONSE=$(printf '%s\n' "$REQUEST" | socat - UNIX-CONNECT:/tmp/ragex_mcp.sock 2>&1)
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
    echo "  2. Remove socket: rm -f /tmp/ragex_mcp.sock"
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
