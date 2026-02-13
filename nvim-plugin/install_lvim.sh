#!/usr/bin/env bash
# Installation script for ragex.nvim (LunarVim)

set -e

echo "╔══════════════════════════════════════════╗"
echo "║   ragex.nvim LunarVim Installation      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Detect LunarVim installation directory
LVIM_CONFIG_DIR="${LUNARVIM_CONFIG_DIR:-$HOME/.config/lvim}"
LVIM_RUNTIME_DIR="${LUNARVIM_RUNTIME_DIR:-$HOME/.local/share/lunarvim}"

# Installation directory for LunarVim plugins
INSTALL_DIR="$LVIM_RUNTIME_DIR/site/pack/user/start/ragex.nvim"

echo "LunarVim config: $LVIM_CONFIG_DIR"
echo "LunarVim runtime: $LVIM_RUNTIME_DIR"
echo "Installation directory: $INSTALL_DIR"
echo ""

# Check if LunarVim is installed
if [ ! -d "$LVIM_CONFIG_DIR" ]; then
  echo "Error: LunarVim not found at $LVIM_CONFIG_DIR"
  echo "Please install LunarVim first: https://www.lunarvim.org/docs/installation"
  exit 1
fi

echo "✓ LunarVim detected"
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
cp LICENSE "$INSTALL_DIR/" 2>/dev/null || true
cp COMMANDS_REFERENCE.md "$INSTALL_DIR/" 2>/dev/null || true

echo ""
echo "✓ Installation complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Next steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Add to your LunarVim config ($LVIM_CONFIG_DIR/config.lua):"
echo ""
echo "   -- Ragex integration"
echo "   require('ragex').setup({"
echo "     ragex_path = vim.fn.expand('$HOME/Proyectos/Oeditus/ragex'),"
echo "     socket_path = '/tmp/ragex_mcp.sock',"
echo "     enabled = true,"
echo "     debug = false,"
echo "     auto_analyze = false,"
echo "   })"
echo ""
echo "   -- Optional: Add keybindings"
echo "   lvim.keys.normal_mode['<leader>rs'] = ':Ragex search<CR>'"
echo "   lvim.keys.normal_mode['<leader>ra'] = ':Ragex analyze_file<CR>'"
echo "   lvim.keys.normal_mode['<leader>rA'] = ':Ragex analyze_directory<CR>'"
echo ""
echo "2. Start Ragex MCP server (in a separate terminal):"
echo "   cd $HOME/Proyectos/Oeditus/ragex"
echo "   mix ragex.server"
echo ""
echo "3. Restart LunarVim or reload config:"
echo "   :LvimReload"
echo ""
echo "4. Use in LunarVim:"
echo "   :Ragex search                # Semantic search"
echo "   :Ragex analyze_directory     # Index your project"
echo "   :Ragex find_duplicates       # Find duplicate code"
echo "   :Ragex semantic_operations   # Phase D features"
echo ""
echo "5. Check health:"
echo "   :checkhealth ragex"
echo ""
echo "6. See all commands (60+):"
echo "   :Ragex <Tab>                 # Press Tab for completion"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Documentation:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  README:           $INSTALL_DIR/README.md"
echo "  Commands:         $INSTALL_DIR/COMMANDS_REFERENCE.md"
echo "  Online:           https://github.com/Oeditus/ragex"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Enjoy coding with Ragex + LunarVim! 🚀"
echo ""
