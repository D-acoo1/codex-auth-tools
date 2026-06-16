#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/CodexBalance"
LOG_DIR="$HOME/Library/Logs/CodexBalance"
BIN="$APP_SUPPORT/CodexBalance"
LABEL="${CODEX_BALANCE_LAUNCHD_LABEL:-com.codexlocaltools.codex-balance}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

cd "$ROOT/codex-balance"
swift build -c release
BUILT_BIN="$(swift build -c release --show-bin-path)/CodexBalance"

mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$HOME/Library/LaunchAgents"
if [[ -x "$BIN" ]]; then
  cp "$BIN" "$BIN.bak.$(date +%Y%m%d-%H%M%S)"
fi
install -m 755 "$BUILT_BIN" "$BIN"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --identifier CodexBalance "$BIN" >/dev/null 2>&1 || true
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST

while IFS= read -r candidate_plist; do
  if [[ "$candidate_plist" == "$PLIST" ]]; then
    continue
  fi

  candidate_bin="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$candidate_plist" 2>/dev/null || true)"
  if [[ "$candidate_bin" != "$BIN" ]]; then
    continue
  fi

  candidate_label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$candidate_plist" 2>/dev/null || true)"
  if [[ -n "$candidate_label" ]]; then
    launchctl bootout "gui/$(id -u)/$candidate_label" 2>/dev/null || true
  fi
  launchctl bootout "gui/$(id -u)" "$candidate_plist" 2>/dev/null || true
  rm -f "$candidate_plist"
done < <(find "$HOME/Library/LaunchAgents" -maxdepth 1 -type f \( -iname '*codex*balance*.plist' -o -iname '*CodexBalance*.plist' \) -print 2>/dev/null)

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" || true

printf 'Installed CodexBalance: %s\n' "$BIN"
printf 'LaunchAgent: %s\n' "$PLIST"
