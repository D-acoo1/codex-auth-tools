#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PARENT="${CODEX_AUTH_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$TMP_PARENT"
WORK="$(mktemp -d "$TMP_PARENT/codex-auth-tools-readme.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/codex-balance"
swift build -c debug --scratch-path "$WORK/swift-build" >/dev/null
BIN="$(swift build -c debug --scratch-path "$WORK/swift-build" --show-bin-path)/CodexBalance"

mkdir -p "$WORK/home-en" "$WORK/home-zh-Hans"
EN_TMP="$WORK/popover-sample-en.png"
ZH_TMP="$WORK/popover-sample-zh-Hans.png"
STATUS_TMP="$WORK/status-bar.png"

HOME="$WORK/home-en" TZ=UTC CODEX_BALANCE_LANG=en \
  "$BIN" --render-readme-sample "$EN_TMP" "$STATUS_TMP"
HOME="$WORK/home-zh-Hans" TZ=UTC CODEX_BALANCE_LANG=zh-Hans \
  "$BIN" --render-readme-sample "$ZH_TMP"

python3 - "$EN_TMP" "$ZH_TMP" "$STATUS_TMP" <<'PY'
from pathlib import Path
import struct
import sys

signature = b"\x89PNG\r\n\x1a\n"
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    data = path.read_bytes()
    if not data.startswith(signature):
        raise SystemExit(f"Not a PNG: {path}")
    output = bytearray(signature)
    offset = len(signature)
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        chunk = data[offset:end]
        kind = data[offset + 4:offset + 8]
        if len(chunk) != 12 + length:
            raise SystemExit(f"Truncated PNG chunk in {path}")
        if kind[0] & 0x20 == 0:  # Keep only critical PNG chunks.
            output.extend(chunk)
        offset = end
        if kind == b"IEND":
            break
    path.write_bytes(output)
PY

for file in "$EN_TMP" "$ZH_TMP"; do
  width="$(/usr/bin/sips -g pixelWidth "$file" | /usr/bin/awk '/pixelWidth/ {print $2}')"
  height="$(/usr/bin/sips -g pixelHeight "$file" | /usr/bin/awk '/pixelHeight/ {print $2}')"
  [[ $((width % 410)) -eq 0 && $((height % 404)) -eq 0 && $((width / 410)) -eq $((height / 404)) ]] || {
    printf 'Unexpected popover sample size: %sx%s (%s)\n' "$width" "$height" "$file" >&2
    exit 1
  }
done

/usr/bin/ditto "$EN_TMP" "$ROOT/assets/popover-sample-en.png"
/usr/bin/ditto "$ZH_TMP" "$ROOT/assets/popover-sample-zh-Hans.png"
/usr/bin/ditto "$STATUS_TMP" "$ROOT/assets/status-bar.png"

printf 'Rendered production UI samples:\n'
printf '  %s\n' "$ROOT/assets/status-bar.png"
printf '  %s\n' "$ROOT/assets/popover-sample-en.png"
printf '  %s\n' "$ROOT/assets/popover-sample-zh-Hans.png"
