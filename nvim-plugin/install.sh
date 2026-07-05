#!/usr/bin/env bash
# Installation script for ragex.nvim

set -e

echo "╔══════════════════════════════════════════╗"
echo "║   ragex.nvim Installation Script        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Detect installation directory
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/plugins/start/ragex.nvim"

echo "Installation directory: $INSTALL_DIR"
echo ""

# Create directory if it doesn't exist
if [ ! -d "$INSTALL_DIR" ]; then
  echo "Creating installation directory..."
  mkdir -p "$INSTALL_DIR"
fi

# Copy files
echo "Copying plugin files..."
cp -r lua "$INSTALL_DIR/"
cp -r plugin "$INSTALL_DIR/"
cp README.md "$INSTALL_DIR/"
cp LICENSE "$INSTALL_DIR/"

echo ""
echo "✓ Installation complete!"
echo ""
echo "Next steps:"
echo "1. Add to your NeoVim config (init.lua):"
echo ""
echo "   require('ragex').setup({"
echo "     ragex_path = vim.fn.expand('~/path/to/ragex'),"
echo "   })"
echo ""
echo "2. Start Ragex MCP server:"
echo "   cd ~/path/to/ragex && mix run --no-halt &"
echo ""
echo "3. Use in NeoVim:"
echo "   :Ragex search"
echo "   :Ragex analyze_directory"
echo ""
echo "4. Check health:"
echo "   :checkhealth ragex"
echo ""
echo "For more information, see: $INSTALL_DIR/README.md"
