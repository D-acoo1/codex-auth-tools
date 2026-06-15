#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODEX_HOME="$TMP/codex-home"
export CODEX_AC_HOME="$TMP/codex-ac"
export CODEX_BALANCE_STATE_DIR="$TMP/codex-balance-state"
export CODEX_AC_LIB="$ROOT/codex-auth/lib"
mkdir -p "$CODEX_HOME" "$CODEX_AC_HOME" "$CODEX_BALANCE_STATE_DIR"

CA="$ROOT/codex-auth/bin/codex-ac"
PYTHON_BIN="$(command -v python3)"
NODE_BIN="$(command -v node || true)"
if [[ -z "${NODE_BIN:-}" ]]; then
  echo "node is required for ca list" >&2
  exit 1
fi
SAFE_PATH="/bin:$(dirname "$PYTHON_BIN"):$(dirname "$NODE_BIN")"
run_ca_no_security() {
  env CODEX_HOME="$CODEX_HOME" CODEX_AC_HOME="$CODEX_AC_HOME" CODEX_AC_LIB="$CODEX_AC_LIB" PATH="$SAFE_PATH" "$CA" "$@"
}
run_ca() {
  env CODEX_HOME="$CODEX_HOME" CODEX_AC_HOME="$CODEX_AC_HOME" CODEX_AC_LIB="$CODEX_AC_LIB" "$CA" "$@"
}
assert_contains() {
  local file="$1" needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "expected to find '$needle' in $file" >&2
    cat "$file" >&2 || true
    exit 1
  fi
}
assert_not_contains() {
  local file="$1" needle="$2"
  if grep -Fq "$needle" "$file"; then
    echo "did not expect to find '$needle' in $file" >&2
    cat "$file" >&2 || true
    exit 1
  fi
}

"$PYTHON_BIN" - "$CODEX_HOME/auth.json" <<'PY'
import base64, json, sys
from pathlib import Path

def b64(obj):
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

payload = {
    "email": "demo@example.com",
    "name": "Demo User",
    "sub": "user-demo",
    "https://api.openai.com/auth": {
        "chatgpt_user_id": "user-demo",
        "chatgpt_account_id": "acct-demo",
        "chatgpt_plan_type": "pro",
    },
}
auth = {
    "auth_mode": "chatgpt",
    "tokens": {
        "access_token": "fake-access-token",
        "id_token": f"{b64({'alg':'none'})}.{b64(payload)}.sig",
        "account_id": "acct-demo",
    },
}
Path(sys.argv[1]).write_text(json.dumps(auth, indent=2) + "\n")
PY
cat > "$CODEX_HOME/config.toml" <<'EOF_CONFIG'
approval_policy = "never"
model = "gpt-5-codex"

[profiles.default]
model = "gpt-5-codex"
EOF_CONFIG

run_ca import fox "$CODEX_HOME/auth.json" --force >/dev/null
printf 'sandbox-fake-key\n' | run_ca_no_security add-api relay --base-url https://relay.example.test/v1 --provider relay --model gpt-5-codex --wire-api responses --force >/dev/null

run_ca s relay --no-backup >/dev/null
[[ "$(run_ca current)" == "relay" ]]
assert_contains "$CODEX_HOME/config.toml" 'model_provider = "relay"'
assert_contains "$CODEX_HOME/config.toml" '[model_providers.relay]'
assert_contains "$CODEX_HOME/config.toml" 'base_url = "https://relay.example.test/v1"'
assert_contains "$CODEX_HOME/config.toml" 'wire_api = "responses"'
assert_contains "$CODEX_HOME/config.toml" '[model_providers.relay.auth]'
assert_contains "$CODEX_HOME/config.toml" 'command = '
assert_not_contains "$CODEX_HOME/config.toml" 'sandbox-fake-key'
"$PYTHON_BIN" - "$CODEX_HOME/auth.json" <<'PY'
import json, sys
obj=json.load(open(sys.argv[1]))
assert obj.get('auth_mode') == 'chatgpt', obj
assert obj.get('tokens', {}).get('access_token') == 'fake-access-token', obj
assert 'OPENAI_API_KEY' not in obj, obj
PY
[[ "$($CODEX_AC_HOME/helpers/relay-key.sh)" == "sandbox-fake-key" ]]
run_ca ll --cached --alias --no-color > "$TMP/list-api.txt"
assert_contains "$TMP/list-api.txt" '* 01 api:relay.example.test/v1'
assert_contains "$TMP/list-api.txt" 'API'
assert_contains "$TMP/list-api.txt" 'relay'

swift build -c release --package-path "$ROOT/codex-balance" >/dev/null
BALANCE_BIN="$(swift build -c release --show-bin-path --package-path "$ROOT/codex-balance")/CodexBalance"
CODEX_HOME="$CODEX_HOME" CODEX_AC_HOME="$CODEX_AC_HOME" CODEX_BALANCE_STATE_DIR="$CODEX_BALANCE_STATE_DIR" "$BALANCE_BIN" --once > "$TMP/balance-api.json"
"$PYTHON_BIN" - "$TMP/balance-api.json" <<'PY'
import json, sys
obj=json.load(open(sys.argv[1]))
assert obj["ok"] is True, obj
assert obj["kind"] == "api", obj
assert obj["alias"] == "relay", obj
assert obj["base_url"] == "https://relay.example.test/v1", obj
assert obj["title"] == "API / -", obj
PY

run_ca s fox --skip-expiry-check --no-backup >/dev/null
[[ "$(run_ca current)" == "fox" ]]
assert_not_contains "$CODEX_HOME/config.toml" 'model_provider = "relay"'
assert_not_contains "$CODEX_HOME/config.toml" '[model_providers.relay]'
assert_not_contains "$CODEX_HOME/config.toml" 'relay.example.test'
"$PYTHON_BIN" - "$CODEX_HOME/auth.json" <<'PY'
import json, sys
obj=json.load(open(sys.argv[1]))
assert obj.get('auth_mode') == 'chatgpt', obj
assert obj.get('tokens', {}).get('account_id') == 'acct-demo', obj
PY
run_ca ll --cached --alias --no-color > "$TMP/list-chatgpt.txt"
assert_contains "$TMP/list-chatgpt.txt" '* 01 demo@example.com'
assert_contains "$TMP/list-chatgpt.txt" 'fox'

echo "blackbox ca/balance sandbox test passed"
