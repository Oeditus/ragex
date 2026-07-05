#!/bin/bash

# Run MCP server with comprehensive logging
# All logs go to /tmp/ragex_debug.log
# Only JSON-RPC messages go to stdout

LOG_FILE="${RAGEX_LOG_FILE:-/tmp/ragex_debug.log}"

echo "=== Starting Ragex MCP Server ===" > "$LOG_FILE"
echo "Timestamp: $(date -Iseconds)" >> "$LOG_FILE"
echo "PID: $$" >> "$LOG_FILE"
echo "Logs: $LOG_FILE" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Redirect stderr to log file, keep stdout for MCP protocol
exec 2>>"$LOG_FILE"

# Set log level to debug
export ELIXIR_ERL_OPTIONS="-kernel logger_level debug"

# Run the server
echo "Starting mix run..." >> "$LOG_FILE"
# IMPORTANT: --no-compile prevents compilation messages on stdout
mix run --no-halt --no-compile
