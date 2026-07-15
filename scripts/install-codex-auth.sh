#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
LIB_DIR="$PREFIX/lib/codex-ac"
BIN_DIR="$PREFIX/bin"
KEEPALIVE_LABEL="${CODEX_AUTH_KEEPALIVE_LABEL:-com.codexlocaltools.codex-auth-keepalive}"
KEEPALIVE_PLIST="$HOME/Library/LaunchAgents/$KEEPALIVE_LABEL.plist"
KEEPALIVE_LOG_DIR="$HOME/Library/Logs/CodexAuth"
START_KEEPALIVE=1

usage() {
  cat <<USAGE
Usage: ./scripts/install-codex-auth.sh [--no-start]

Options:
  --no-start  Install the 24-hour keepalive LaunchAgent without loading it.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) START_KEEPALIVE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LIB_DIR" "$BIN_DIR"
install -m 700 "$ROOT/codex-auth/lib/codex-ac.py" "$LIB_DIR/codex-ac.py"
install -m 700 "$ROOT/codex-auth/lib/list.mjs" "$LIB_DIR/list.mjs"
install -m 700 "$ROOT/codex-auth/bin/codex-ac" "$BIN_DIR/codex-ac"
ln -sf "$BIN_DIR/codex-ac" "$BIN_DIR/ca"

install_keepalive() {
  local python_bin codex_bin node_bin path_value tmp_plist
  python_bin="$(command -v python3 || true)"
  if [[ -z "$python_bin" ]]; then
    printf 'python3 is required by codex-ac.\n' >&2
    exit 1
  fi
  codex_bin="${CODEX_BIN:-$(command -v codex || true)}"
  node_bin="$(command -v node || true)"
  path_value="$BIN_DIR:$(dirname "$python_bin")"
  if [[ -n "$node_bin" ]]; then
    path_value="$path_value:$(dirname "$node_bin")"
  fi
  path_value="$path_value:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$(dirname "$KEEPALIVE_PLIST")" "$KEEPALIVE_LOG_DIR"
  if [[ "$START_KEEPALIVE" == "1" && "${CODEX_AUTH_KEEPALIVE_NO_START:-0}" != "1" ]]; then
    local state attempt
    state=""
    for ((attempt = 0; attempt < 120; attempt++)); do
      state="$(launchctl print "gui/$(id -u)/$KEEPALIVE_LABEL" 2>/dev/null || true)"
      [[ "$state" != *"state = running"* ]] && break
      sleep 1
    done
    if [[ "$state" == *"state = running"* ]]; then
      printf 'Keepalive is still running; installation stopped to avoid interrupting token renewal.\n' >&2
      exit 1
    fi
    launchctl bootout "gui/$(id -u)/$KEEPALIVE_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)" "$KEEPALIVE_PLIST" 2>/dev/null || true
  fi
  tmp_plist="$KEEPALIVE_PLIST.tmp.$$"
  "$python_bin" - "$tmp_plist" "$KEEPALIVE_LABEL" "$BIN_DIR/codex-ac" "$KEEPALIVE_LOG_DIR" "$path_value" "$codex_bin" <<'PY'
import os
import plistlib
import sys

dst, label, executable, log_dir, path_value, codex_bin = sys.argv[1:]
environment = {"PATH": path_value}
if codex_bin:
    environment["CODEX_BIN"] = codex_bin
payload = {
    "Label": label,
    "ProgramArguments": [executable, "keepalive", "--quiet"],
    "RunAtLoad": True,
    "StartInterval": 86400,
    "LimitLoadToSessionType": "Aqua",
    "ProcessType": "Background",
    "ThrottleInterval": 300,
    "StandardOutPath": os.path.join(log_dir, "keepalive.stdout.log"),
    "StandardErrorPath": os.path.join(log_dir, "keepalive.stderr.log"),
    "EnvironmentVariables": environment,
}
with open(dst, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
os.chmod(dst, 0o644)
PY
  plutil -lint "$tmp_plist" >/dev/null
  mv "$tmp_plist" "$KEEPALIVE_PLIST"
  if [[ "$START_KEEPALIVE" == "1" && "${CODEX_AUTH_KEEPALIVE_NO_START:-0}" != "1" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$KEEPALIVE_PLIST"
  fi
}

install_keepalive

printf 'Installed codex-auth to %s\n' "$PREFIX"
printf 'Keepalive LaunchAgent: %s (checks every 24 hours)\n' "$KEEPALIVE_PLIST"
printf 'Commands: codex-ac --help, ca ll, ca keepalive --dry-run\n'
