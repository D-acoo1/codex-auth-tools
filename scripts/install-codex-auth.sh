#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
LIB_DIR="$PREFIX/lib/codex-ac"
BIN_DIR="$PREFIX/bin"

mkdir -p "$LIB_DIR" "$BIN_DIR"
install -m 700 "$ROOT/codex-auth/lib/codex-ac.py" "$LIB_DIR/codex-ac.py"
install -m 700 "$ROOT/codex-auth/lib/list.mjs" "$LIB_DIR/list.mjs"
install -m 700 "$ROOT/codex-auth/bin/codex-ac" "$BIN_DIR/codex-ac"
ln -sf "$BIN_DIR/codex-ac" "$BIN_DIR/ca"

printf 'Installed codex-auth to %s\n' "$PREFIX"
printf 'Commands: codex-ac --help, ca ll\n'
