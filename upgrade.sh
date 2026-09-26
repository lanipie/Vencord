#!/usr/bin/env bash
set -euo pipefail

VENCORD_DIR="${1:-$HOME/git/Vencord}"
PLUGIN_REPO="https://github.com/0x00-sys/streamBitrateBooster"
PLUGIN_DIR="$VENCORD_DIR/src/userplugins/streamBitrateBooster"

# 1. Update Vencord to latest main
cd "$VENCORD_DIR"
git fetch origin
git checkout main
git pull origin main

# 2. Ensure userplugins dir exists
mkdir -p "$VENCORD_DIR/src/userplugins"

# 3. Clone or pull the plugin
if [ -d "$PLUGIN_DIR/.git" ]; then
    cd "$PLUGIN_DIR"
    git pull
else
    git clone "$PLUGIN_REPO" "$PLUGIN_DIR"
fi

echo "Done. Run 'pnpm build' in $VENCORD_DIR"
