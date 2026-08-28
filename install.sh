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

if [[ ! -t 0 ]]; then
  error "stdin is not a terminal — this almost always means you ran 'curl ... | bash'.
That pattern breaks sudo prompts. Re-run with one of:
  bash <(curl -fsSL https://cdn.supplycart.my/shells/install.sh)
  curl -fsSL https://cdn.supplycart.my/shells/install.sh -o /tmp/install.sh && bash /tmp/install.sh"
fi

info "Requesting sudo password (used for installer + symlink — asked once, reused)..."
read -rsp "Password: " SUDO_PASSWORD
echo ""
if ! sudo -S -v <<< "$SUDO_PASSWORD" 2>/dev/null; then
  error "Incorrect sudo password."
fi

run_sudo() {
  sudo -S -p "" "$@" <<< "$SUDO_PASSWORD"
}

trap 'unset SUDO_PASSWORD' EXIT

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

PACKAGES=(fzf jq kubernetes-cli)
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
  run_sudo installer -verbose -pkg /tmp/AWSCLIV2.pkg -target /
  rm /tmp/AWSCLIV2.pkg
  success "AWS CLI v2 installed"
fi

PLUGIN_BIN="/usr/local/bin/session-manager-plugin"
PLUGIN_REAL="/usr/local/sessionmanagerplugin/bin/session-manager-plugin"

if [[ -x "$PLUGIN_BIN" || -x "$PLUGIN_REAL" ]]; then
  success "session-manager-plugin already installed at $([[ -x $PLUGIN_BIN ]] && echo $PLUGIN_BIN || echo $PLUGIN_REAL)"
else
  if [[ "$(uname -m)" == "arm64" ]]; then
    BUNDLE_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/sessionmanager-bundle.zip"
  else
    BUNDLE_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip"
  fi
  info "Installing session-manager-plugin from AWS bundle..."
  BUNDLE_DIR=$(mktemp -d)
  curl -fsSL "$BUNDLE_URL" -o "$BUNDLE_DIR/sessionmanager-bundle.zip"
  unzip -q "$BUNDLE_DIR/sessionmanager-bundle.zip" -d "$BUNDLE_DIR"
  run_sudo "$BUNDLE_DIR/sessionmanager-bundle/install" -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin
  rm -rf "$BUNDLE_DIR"
  if [[ -x "$PLUGIN_BIN" || -x "$PLUGIN_REAL" ]]; then
    success "session-manager-plugin installed"
  else
    error "session-manager-plugin install completed but binary not found at $PLUGIN_BIN or $PLUGIN_REAL"
  fi
fi

if ! command -v session-manager-plugin &>/dev/null; then
  warn "/usr/local/bin not on PATH for this shell — AWS CLI will still find the plugin by absolute path."
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
  run_sudo mkdir -p /usr/local/bin
fi
if [[ -L "$SYMLINK" && "$(readlink "$SYMLINK")" == "$SSM_SCRIPT" ]]; then
  success "ssm symlink already in place"
else
  info "Creating symlink $SYMLINK -> $SSM_SCRIPT..."
  run_sudo ln -sf "$SSM_SCRIPT" "$SYMLINK"
  success "ssm command installed"
fi

echo ""
success "All done. Fill in ~/.ssm/config.json, then run 'ssm help'."
