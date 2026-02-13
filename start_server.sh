#!/usr/bin/env bash
# Start Ragex MCP Server
# This script starts the Ragex application which includes the MCP socket server

set -e

cd "$(dirname "$0")"

echo "════════════════════════════════════════════════════════"
echo "  Starting Ragex MCP Server"
echo "════════════════════════════════════════════════════════"
echo ""
echo "Socket path: /tmp/ragex_mcp.sock"
echo "Log file: /tmp/ragex_server.log"
echo ""
echo "Press Ctrl+C to stop the server"
echo "════════════════════════════════════════════════════════"
echo ""

# Remove old socket file if it exists
rm -f /tmp/ragex_mcp.sock

# Start the server
# Use --no-halt to keep it running
# Redirect output to log file
exec mix run --no-halt 2>&1 | tee /tmp/ragex_server.log
