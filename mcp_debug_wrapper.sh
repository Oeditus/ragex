#!/bin/bash

# MCP debug wrapper - logs all stdin/stdout traffic
# Use this instead of start_mcp.sh to debug client communication

LOG_DIR="/tmp/ragex_mcp_debug"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STDIN_LOG="$LOG_DIR/stdin_${TIMESTAMP}.log"
STDOUT_LOG="$LOG_DIR/stdout_${TIMESTAMP}.log"
STDERR_LOG="$LOG_DIR/stderr_${TIMESTAMP}.log"

echo "=== MCP Debug Wrapper ===" >&2
echo "STDIN log:  $STDIN_LOG" >&2
echo "STDOUT log: $STDOUT_LOG" >&2
echo "STDERR log: $STDERR_LOG" >&2
echo "" >&2

# Compile first
mix compile 2>&1 >/dev/null

# Use tee to log stdin/stdout while passing through
# stderr goes directly to log file
exec 3>&1  # Save original stdout
exec 4>&2  # Save original stderr

# Start the server with tee on both stdin and stdout
{
    tee "$STDIN_LOG" | \
    mix run --no-halt --no-compile 2>"$STDERR_LOG" | \
    tee "$STDOUT_LOG"
}
