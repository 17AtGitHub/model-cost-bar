#!/usr/bin/env bash
# Installs the model-cost-bar plugin for SwiftBar on macOS.
# Works from a clone (./install.sh) or piped from GitHub (curl ... | bash).
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/17AtGitHub/model-cost-bar/main"
PLUGIN="model-cost.1h.sh"

if [ "$(uname)" != Darwin ]; then
  echo "model-cost-bar is a macOS menu bar plugin." >&2
  exit 1
fi

if [ ! -d /Applications/SwiftBar.app ] && [ ! -d "$HOME/Applications/SwiftBar.app" ]; then
  if ! command -v brew >/dev/null; then
    echo "Install SwiftBar first (https://swiftbar.app or https://brew.sh), then rerun this script." >&2
    exit 1
  fi
  echo "Installing SwiftBar..."
  brew install --cask swiftbar
fi

plugin_dir="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$plugin_dir" ]; then
  plugin_dir="$HOME/.swiftbar"
  defaults write com.ameba.SwiftBar PluginDirectory "$plugin_dir"
fi
plugin_dir="${plugin_dir/#\~/$HOME}"
mkdir -p "$plugin_dir"

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
fetch() {
  if [ -f "$src_dir/$1" ]; then
    cp "$src_dir/$1" "$2"
  else
    curl -fsSL "$REPO_RAW/$1" -o "$2"
  fi
}

fetch "$PLUGIN" "$plugin_dir/$PLUGIN"
chmod +x "$plugin_dir/$PLUGIN"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/model-cost"
mkdir -p "$cache_dir"
[ -s "$cache_dir/prices.tsv" ] || fetch prices.tsv "$cache_dir/prices.tsv"

if pgrep -xq SwiftBar; then
  open -g "swiftbar://refreshallplugins"
else
  open -a SwiftBar
fi

echo "Installed to $plugin_dir/$PLUGIN. Look for the model price in your menu bar."
