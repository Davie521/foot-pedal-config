#!/bin/bash
set -euo pipefail

# LinTx foot pedal one-click installer for macOS
# Usage: curl -sL <raw-url>/install.sh | bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Check prerequisites ---

if [[ "$(uname)" != "Darwin" ]]; then
    error "This script only works on macOS."
fi

if ! command -v brew &>/dev/null; then
    error "Homebrew is required. Install it from https://brew.sh"
fi

# --- Install dependencies ---

if ! [ -d "/Applications/Karabiner-Elements.app" ]; then
    warn "Installing Karabiner-Elements..."
    brew install --cask karabiner-elements
else
    info "Karabiner-Elements already installed"
fi

if ! [ -d "/Applications/Hammerspoon.app" ]; then
    warn "Installing Hammerspoon..."
    brew install --cask hammerspoon
else
    info "Hammerspoon already installed"
fi

# --- Locate config files ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/karabiner.json" ] && [ -f "$SCRIPT_DIR/init.lua" ]; then
    CONFIG_DIR="$SCRIPT_DIR"
else
    # If running via curl pipe, download files
    CONFIG_DIR="$(mktemp -d)"
    trap 'rm -rf "$CONFIG_DIR"' EXIT
    REPO="Davie521/foot-pedal-config"
    warn "Downloading config files..."
    curl -sL "https://raw.githubusercontent.com/$REPO/main/karabiner.json" -o "$CONFIG_DIR/karabiner.json"
    curl -sL "https://raw.githubusercontent.com/$REPO/main/init.lua" -o "$CONFIG_DIR/init.lua"
fi

# --- Deploy Karabiner config ---

KARABINER_DIR="$HOME/.config/karabiner"
mkdir -p "$KARABINER_DIR"

if [ -f "$KARABINER_DIR/karabiner.json" ]; then
    cp "$KARABINER_DIR/karabiner.json" "$KARABINER_DIR/karabiner.json.bak"
    warn "Backed up existing karabiner.json → karabiner.json.bak"
    warn "NOTE: This REPLACES your entire Karabiner config."
    warn "If you have other rules, merge manually from the .bak file."
fi

cp "$CONFIG_DIR/karabiner.json" "$KARABINER_DIR/karabiner.json"
info "Deployed karabiner.json"

# --- Deploy Hammerspoon config ---

HS_DIR="$HOME/.hammerspoon"
mkdir -p "$HS_DIR"

if [ -f "$HS_DIR/init.lua" ]; then
    cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.bak"
    warn "Backed up existing init.lua → init.lua.bak"
fi

cp "$CONFIG_DIR/init.lua" "$HS_DIR/init.lua"
info "Deployed init.lua"

# --- Reload Hammerspoon ---

if pgrep -q Hammerspoon; then
    hs -c "hs.reload()" 2>/dev/null || true
    info "Hammerspoon reloaded"
else
    warn "Hammerspoon is not running. Please launch it manually."
fi

# --- Done ---

echo ""
info "Installation complete!"
echo ""
echo "  Next steps:"
echo "  1. Open Karabiner-Elements → check that the LinTx rule is active"
echo "  2. Grant Hammerspoon Accessibility & Input Monitoring permissions"
echo "     (System Settings → Privacy & Security)"
echo "  3. Configure Wispr Flow PTT trigger to Mouse Button 4"
echo "  4. Plug in your LinTx foot pedal and test!"
echo ""
echo "  Short tap → Enter | Long press → Push-to-Talk"
echo ""
