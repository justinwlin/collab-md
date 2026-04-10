#!/bin/sh
# CollabMd CLI Installer — downloads a prebuilt binary. No dependencies needed.
# Usage: curl -sSL https://raw.githubusercontent.com/justinwlin/collab-md/main/install.sh | sh
set -e

REPO="justinwlin/collab-md"
INSTALL_DIR="${COLLAB_INSTALL_DIR:-$HOME/.local/bin}"

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;
    *)
        echo "Error: Unsupported OS: $OS"
        echo "Only Linux and macOS are supported."
        exit 1
        ;;
esac

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)    ARCH="x86_64" ;;
    aarch64|arm64)   ARCH="aarch64" ;;
    *)
        echo "Error: Unsupported architecture: $ARCH"
        echo "Only x86_64 and arm64/aarch64 are supported."
        exit 1
        ;;
esac

BINARY="collabmd-${OS}-${ARCH}"
URL="https://github.com/${REPO}/releases/latest/download/${BINARY}"

echo "==> Installing collabmd for ${OS}/${ARCH}..."
mkdir -p "$INSTALL_DIR"

# Download binary
if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -sSL -w '%{http_code}' "$URL" -o "${INSTALL_DIR}/collabmd")
    if [ "$HTTP_CODE" != "200" ]; then
        rm -f "${INSTALL_DIR}/collabmd"
        echo "Error: Download failed (HTTP $HTTP_CODE)"
        echo "No release found. You can build from source instead:"
        echo "  git clone https://github.com/${REPO}.git"
        echo "  cd collab-md/cli-rust && cargo install --path . --bin collabmd"
        exit 1
    fi
elif command -v wget >/dev/null 2>&1; then
    wget -q "$URL" -O "${INSTALL_DIR}/collabmd" || {
        rm -f "${INSTALL_DIR}/collabmd"
        echo "Error: Download failed."
        echo "No release found. You can build from source:"
        echo "  git clone https://github.com/${REPO}.git"
        echo "  cd collab-md/cli-rust && cargo install --path . --bin collabmd"
        exit 1
    }
else
    echo "Error: curl or wget is required to download the binary."
    exit 1
fi

chmod +x "${INSTALL_DIR}/collabmd"

# Verify the binary runs
if "${INSTALL_DIR}/collabmd" --version >/dev/null 2>&1; then
    VERSION=$("${INSTALL_DIR}/collabmd" --version 2>/dev/null || echo "unknown")
    echo "==> Installed: $VERSION"
else
    echo "==> Binary installed (could not verify version)"
fi

# Check if INSTALL_DIR is in PATH
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*)
        echo "==> Ready! Run 'collabmd --help' to get started."
        ;;
    *)
        echo ""
        echo "==> Installed to ${INSTALL_DIR}/collabmd"
        echo ""
        echo "Add this directory to your PATH:"
        echo ""
        SHELL_NAME="$(basename "${SHELL:-/bin/sh}")"
        case "$SHELL_NAME" in
            zsh)
                echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
                echo "  source ~/.zshrc"
                ;;
            bash)
                echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
                echo "  source ~/.bashrc"
                ;;
            fish)
                echo "  fish_add_path ~/.local/bin"
                ;;
            *)
                echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.profile"
                echo "  source ~/.profile"
                ;;
        esac
        echo ""
        echo "Then run: collabmd --help"
        ;;
esac

echo ""
echo "To uninstall: collabmd uninstall"
