#!/bin/bash

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

if [[ "$(uname)" != "Darwin" ]]; then
  error "This script only supports macOS."
fi

if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  success "Homebrew already installed"
fi

PACKAGES=(awscli fzf jq)
for pkg in "${PACKAGES[@]}"; do
  if brew list "$pkg" &>/dev/null; then
    success "$pkg already installed"
  else
    info "Installing $pkg..."
    brew install "$pkg"
    success "$pkg installed"
  fi
done

CASK="session-manager-plugin"
if brew list --cask "$CASK" &>/dev/null; then
  success "$CASK already installed"
else
  info "Installing $CASK..."
  brew install --cask "$CASK"
  success "$CASK installed"
fi

SSM_DIR="$HOME/.ssm"
SSM_SCRIPT="$SSM_DIR/ssm.sh"
CONFIG_FILE="$SSM_DIR/config.json"
ZSHRC="$HOME/.zshrc"

[[ ! -d "$SSM_DIR" ]] && mkdir -p "$SSM_DIR"

info "Downloading ssm.sh..."
curl -fsSL https://cdn.supplycart.my/shells/ssm.sh -o "$SSM_SCRIPT"
chmod +x "$SSM_SCRIPT"
success "ssm.sh downloaded to $SSM_SCRIPT"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo '{}' > "$CONFIG_FILE"
  success "Created $CONFIG_FILE — fill in your environments before using ssm"
fi

FUNCTION_MARKER="# ssm — AWS SSM helper"
if grep -qF "$FUNCTION_MARKER" "$ZSHRC" 2>/dev/null; then
  success "ssm function already in $ZSHRC"
else
  info "Adding ssm function to $ZSHRC..."
  cat >> "$ZSHRC" <<EOF

$FUNCTION_MARKER
ssm() {
  bash "$SSM_SCRIPT" "\$@"
}
EOF
  success "ssm function added"
fi

source "$ZSHRC"
echo ""
success "All done. Fill in ~/.ssm/config.json with your environments."
