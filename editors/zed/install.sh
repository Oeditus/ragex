#!/usr/bin/env bash
#
# install.sh — install the Ragex Zed config bundle into a project.
#
# Usage:
#   ./install.sh [PROJECT_DIR] [RAGEX_DIR]
#
#   PROJECT_DIR  project that should get a .zed/ config (default: $PWD)
#   RAGEX_DIR    path to the Ragex checkout (default: auto-detected)
#
# Copies settings.json, tasks.json and keymap.json into <PROJECT_DIR>/.zed/,
# rewriting the hard-coded Ragex paths to match RAGEX_DIR. Existing files are
# backed up with a .bak suffix before being overwritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$PWD}"
RAGEX_DIR="${2:-}"

# Auto-detect the Ragex checkout: prefer a sibling of this bundle, else walk up.
if [[ -z "$RAGEX_DIR" ]]; then
  if [[ -x "$SCRIPT_DIR/../../bin/ragex-mcp" ]]; then
    RAGEX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  else
    dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
      if [[ -x "$dir/bin/ragex-mcp" ]]; then
        RAGEX_DIR="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done
  fi
fi

if [[ -z "$RAGEX_DIR" || ! -x "$RAGEX_DIR/bin/ragex-mcp" ]]; then
  echo "error: could not locate a Ragex checkout (bin/ragex-mcp)." >&2
  echo "       pass the path explicitly: $0 PROJECT_DIR RAGEX_DIR" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "error: project directory does not exist: $PROJECT_DIR" >&2
  exit 1
fi

ZED_DIR="$PROJECT_DIR/.zed"
mkdir -p "$ZED_DIR"

echo "Installing Ragex Zed bundle"
echo "  project : $PROJECT_DIR"
echo "  ragex   : $RAGEX_DIR"
echo "  target  : $ZED_DIR"
echo

# Back up and install each file, substituting the Ragex path.
for file in settings.json tasks.json keymap.json; do
  src="$SCRIPT_DIR/$file"
  dst="$ZED_DIR/$file"

  if [[ -f "$dst" ]]; then
    cp "$dst" "$dst.bak"
    echo "  backed up  $dst -> $dst.bak"
  fi

  # Replace the placeholder default path with the real checkout path.
  sed "s#/opt/Proyectos/Oeditus/ragex#$RAGEX_DIR#g" "$src" > "$dst"
  echo "  installed  $dst"
done

echo
echo "Done. Restart Zed (or reload the window) to pick up the config."
echo "Ragex tools will appear in the Agent Panel's context-server list."
