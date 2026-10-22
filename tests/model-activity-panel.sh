#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${CODEX_AUTH_TEST_TMPDIR:-${TMPDIR:-/tmp}}/model-activity-panel.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Same production views/renderer, without the app entry point or quota requests.
awk '/^if let renderIndex = CommandLine.arguments.firstIndex/ {exit} {print}' \
  "$ROOT/codex-balance/Sources/CodexBalance/main.swift" > "$TMP/main.swift"
cat "$ROOT/tests/model-activity-panel.swift" >> "$TMP/main.swift"
swiftc -swift-version 6 -O -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx13.0" "$TMP/main.swift" \
  "$ROOT/codex-balance/Sources/CodexBalance/Localization.swift" \
  "$ROOT/codex-balance/Sources/CodexBalance/ModelActivity.swift" \
  "$ROOT/codex-balance/Sources/CodexBalance/ModelActivityView.swift" -o "$TMP/tests"
CODEX_BALANCE_LANG=en "$TMP/tests" "${1:-$TMP/images}"
