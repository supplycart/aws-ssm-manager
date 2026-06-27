#!/bin/bash

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

if [[ "$(uname)" != "Darwin" ]]; then
  error "This script only supports macOS."
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

load_brew_env() {
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  fi
}

if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew_env
  if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
    echo "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"" >> "$HOME/.zprofile"
    success "Added Homebrew to ~/.zprofile"
  fi
else
  success "Homebrew already installed"
  load_brew_env
fi

PACKAGES=(fzf jq)
for pkg in "${PACKAGES[@]}"; do
  if brew list "$pkg" &>/dev/null; then
    success "$pkg already installed"
  else
    info "Installing $pkg..."
    brew install "$pkg"
    success "$pkg installed"
  fi
done

if command -v aws &>/dev/null && aws --version 2>&1 | grep -q "exe/"; then
  success "AWS CLI v2 already installed"
else
  info "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
  sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
  rm /tmp/AWSCLIV2.pkg
  success "AWS CLI v2 installed"
fi

CASK="session-manager-plugin"
if brew list --cask "$CASK" &>/dev/null; then
  success "$CASK already installed"
else
  info "Installing $CASK..."
  brew install --cask "$CASK"
  success "$CASK installed"
fi

PLUGIN_BIN="/usr/local/bin/session-manager-plugin"
PLUGIN_REAL="/usr/local/sessionmanagerplugin/bin/session-manager-plugin"

if [[ -x "$PLUGIN_BIN" || -x "$PLUGIN_REAL" ]]; then
  success "session-manager-plugin installed at $([[ -x $PLUGIN_BIN ]] && echo $PLUGIN_BIN || echo $PLUGIN_REAL)"
  if ! command -v session-manager-plugin &>/dev/null; then
    warn "/usr/local/bin not on PATH for this shell — AWS CLI will still find the plugin by absolute path, but you may want to add /usr/local/bin to PATH in your shell profile."
  fi
else
  error "session-manager-plugin not found at $PLUGIN_BIN or $PLUGIN_REAL after install. Try: brew reinstall --cask session-manager-plugin"
fi

SSM_DIR="$HOME/.ssm"
SSM_SCRIPT="$SSM_DIR/ssm.sh"
CONFIG_FILE="$SSM_DIR/config.json"

[[ ! -d "$SSM_DIR" ]] && mkdir -p "$SSM_DIR"

info "Downloading ssm.sh..."
curl -fsSL https://cdn.supplycart.my/shells/ssm.sh -o "$SSM_SCRIPT"
chmod +x "$SSM_SCRIPT"
success "ssm.sh downloaded to $SSM_SCRIPT"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo '{}' > "$CONFIG_FILE"
  success "Created $CONFIG_FILE — fill in your environments before using ssm"
fi

SYMLINK="/usr/local/bin/ssm"
if [[ ! -d /usr/local/bin ]]; then
  sudo mkdir -p /usr/local/bin
fi
if [[ -L "$SYMLINK" && "$(readlink "$SYMLINK")" == "$SSM_SCRIPT" ]]; then
  success "ssm symlink already in place"
else
  info "Creating symlink $SYMLINK -> $SSM_SCRIPT..."
  sudo ln -sf "$SSM_SCRIPT" "$SYMLINK"
  success "ssm command installed"
fi

echo ""
success "All done. Fill in ~/.ssm/config.json, then run 'ssm help'."
