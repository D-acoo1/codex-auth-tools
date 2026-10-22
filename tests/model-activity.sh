#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${CODEX_AUTH_TEST_TMPDIR:-${TMPDIR:-/tmp}}/model-activity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/tests/model-activity.swift" "$TMP/main.swift"
swiftc -swift-version 6 -O -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx13.0" \
  "$ROOT/codex-balance/Sources/CodexBalance/ModelActivity.swift" "$TMP/main.swift" -o "$TMP/tests"
"$TMP/tests" "$TMP/fixture"
