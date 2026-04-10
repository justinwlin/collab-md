#!/usr/bin/env bash
set -euo pipefail

# CollabMd CLI Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/justinwlin/collab-md/main/install.sh | bash

REPO="justinwlin/collab-md"
INSTALL_DIR="${HOME}/.local/bin"
TEMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

echo "==> Installing CollabMd CLI..."

# Check for Elixir
if ! command -v elixir &>/dev/null; then
  echo "Error: Elixir is required but not installed."
  echo "Install via: brew install elixir  (macOS)"
  echo "         or: asdf install elixir latest"
  exit 1
fi

if ! command -v mix &>/dev/null; then
  echo "Error: mix not found. Ensure Elixir is properly installed."
  exit 1
fi

# Clone just the cli directory
echo "==> Fetching source..."
git clone --depth 1 "https://github.com/${REPO}.git" "$TEMP_DIR/collab-md" 2>/dev/null

# Build escript
echo "==> Building CLI..."
cd "$TEMP_DIR/collab-md/cli"
mix local.hex --force --if-missing >/dev/null 2>&1
mix deps.get --only prod >/dev/null 2>&1
MIX_ENV=prod mix escript.build >/dev/null 2>&1

# Install
mkdir -p "$INSTALL_DIR"
cp collab_cli "$INSTALL_DIR/collab"
chmod +x "$INSTALL_DIR/collab"

echo ""
echo "==> Installed to $INSTALL_DIR/collab"

# Check PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "NOTE: $INSTALL_DIR is not in your PATH. Add it:"
  echo ""
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
  echo "  source ~/.zshrc"
  echo ""
fi

echo "==> Done! Usage:"
echo ""
echo "  collab create --name yourname          # Create a room"
echo "  collab join CODE --name yourname       # Join a room"
echo "  collab history CODE                    # View version history"
echo "  collab restore CODE VERSION            # Restore a version"
echo "  collab status CODE                     # Room status"
echo ""
echo "Set server: export COLLAB_SERVER=https://collab-md.fly.dev"
