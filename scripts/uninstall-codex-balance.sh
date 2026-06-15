#!/usr/bin/env bash
set -euo pipefail
LABEL="${CODEX_BALANCE_LAUNCHD_LABEL:-com.codexlocaltools.codex-balance}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
printf 'Unloaded %s. Installed binary/data under ~/Library/Application Support/CodexBalance was left intact.\n' "$LABEL"
