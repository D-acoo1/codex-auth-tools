#!/bin/bash
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
LIB_DIR="$PREFIX/lib/codex-ac"
BIN_DIR="$PREFIX/bin"
KEEPALIVE_LABEL="${CODEX_AUTH_KEEPALIVE_LABEL:-com.codexlocaltools.codex-auth-keepalive}"
KEEPALIVE_PLIST="$HOME/Library/LaunchAgents/$KEEPALIVE_LABEL.plist"

state=""
for ((attempt = 0; attempt < 120; attempt++)); do
  state="$(launchctl print "gui/$(id -u)/$KEEPALIVE_LABEL" 2>/dev/null || true)"
  [[ "$state" != *"state = running"* ]] && break
  sleep 1
done
if [[ "$state" == *"state = running"* ]]; then
  printf 'Keepalive is still running; uninstall stopped to avoid interrupting token renewal.\n' >&2
  exit 1
fi
launchctl bootout "gui/$(id -u)/$KEEPALIVE_LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$KEEPALIVE_PLIST" 2>/dev/null || true
rm -f "$KEEPALIVE_PLIST" "$BIN_DIR/codex-ac"
if [[ -L "$BIN_DIR/ca" && "$(readlink "$BIN_DIR/ca")" == "$BIN_DIR/codex-ac" ]]; then
  rm -f "$BIN_DIR/ca"
fi
rm -rf "$LIB_DIR"

printf 'Removed codex-ac and its keepalive LaunchAgent.\n'
printf 'Saved accounts were preserved in %s/.codex-ac\n' "$HOME"
