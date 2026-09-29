#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/balance-account-context.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SOURCE="$ROOT/codex-balance/Sources/CodexBalance/main.swift"

# Compile the unchanged production fetcher with a URLProtocol test transport.
# AppKit presentation and the application entry point are outside this test.
[[ "$(grep -c '^enum CardThemeMode: String {' "$SOURCE")" == 1 ]]
awk '/^enum CardThemeMode: String \{/ {exit} {print}' "$SOURCE" > "$TMP/main.swift"
cat "$ROOT/tests/balance-account-context.swift" >> "$TMP/main.swift"
swiftc -swift-version 6 -O -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx13.0" "$TMP/main.swift" \
  "$ROOT/codex-balance/Sources/CodexBalance/Localization.swift" \
  -o "$TMP/balance-account-context"
"$TMP/balance-account-context"
