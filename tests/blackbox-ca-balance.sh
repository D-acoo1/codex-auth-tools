#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
USAGE_SERVER_PID=""
cleanup() {
  if [[ -n "${USAGE_SERVER_PID:-}" ]]; then
    kill "$USAGE_SERVER_PID" >/dev/null 2>&1 || true
    wait "$USAGE_SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

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
PYTHON_EXE="$("$PYTHON_BIN" -c 'import sys; print(sys.executable)')"
NODE_EXE="$("$NODE_BIN" -p 'process.execPath')"
SAFE_BIN="$TMP/safe-bin"
mkdir -p "$SAFE_BIN"
ln -sf "$PYTHON_EXE" "$SAFE_BIN/python3"
ln -sf "$NODE_EXE" "$SAFE_BIN/node"
SAFE_PATH="/bin:$SAFE_BIN"
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

USAGE_PORT_FILE="$TMP/usage-port"
"$PYTHON_BIN" - "$USAGE_PORT_FILE" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/v1/usage":
            self.send_response(404)
            self.end_headers()
            return
        if self.headers.get("Authorization") != "Bearer sandbox-fake-key":
            self.send_response(401)
            self.end_headers()
            return
        body = {
            "mode": "quota_limited",
            "isValid": True,
            "status": "active",
            "remaining": 12.34,
            "unit": "USD",
            "quota": {"limit": 20.0, "used": 7.66, "remaining": 12.34, "unit": "USD"},
            "usage": {
                "today": {
                    "requests": 9,
                    "input_tokens": 10000,
                    "output_tokens": 2000,
                    "cache_creation_tokens": 100,
                    "cache_read_tokens": 245,
                    "total_tokens": 12345,
                    "cost": 0.5,
                    "actual_cost": 0.42,
                },
                "total": {
                    "requests": 321,
                    "input_tokens": 700000,
                    "output_tokens": 200000,
                    "cache_creation_tokens": 30000,
                    "cache_read_tokens": 57654,
                    "total_tokens": 987654,
                    "cost": 9.99,
                    "actual_cost": 8.76,
                },
                "rpm": 1,
                "tpm": 42,
            },
        }
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
USAGE_SERVER_PID=$!
for _ in {1..50}; do
  [[ -s "$USAGE_PORT_FILE" ]] && break
  sleep 0.1
done
[[ -s "$USAGE_PORT_FILE" ]]
USAGE_BASE_URL="http://127.0.0.1:$(cat "$USAGE_PORT_FILE")/v1"

printf 'sandbox-fake-key\n' | run_ca_no_security add-api relay --base-url "$USAGE_BASE_URL" --provider relay --model gpt-5-codex --wire-api responses --force >/dev/null

run_ca s relay --no-backup >/dev/null
[[ "$(run_ca current)" == "relay" ]]
assert_contains "$CODEX_HOME/config.toml" 'model_provider = "relay"'
assert_contains "$CODEX_HOME/config.toml" '[model_providers.relay]'
assert_contains "$CODEX_HOME/config.toml" "base_url = \"$USAGE_BASE_URL\""
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
assert_contains "$TMP/list-api.txt" '* 01 api:127.0.0.1:'
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
assert obj["base_url"].startswith("http://127.0.0.1:"), obj
assert obj["title"].startswith("API "), obj
assert obj["api_remaining"] == 12.34, obj
assert obj["api_quota_used"] == 7.66, obj
assert obj["api_today_actual_cost"] == 0.42, obj
assert obj["api_total_actual_cost"] == 8.76, obj
assert obj["api_today_tokens"] == 12345, obj
assert obj["api_total_tokens"] == 987654, obj
assert "sandbox-fake-key" not in open(sys.argv[1]).read(), obj
PY

TASK_DB="$CODEX_HOME/state_5.sqlite"
TASK_GLOBAL="$CODEX_HOME/.codex-global-state.json"
TASK_NOW="$(date +%s)"
write_task_db() {
  rm -f "$TASK_DB"
  /usr/bin/sqlite3 "$TASK_DB" <<'SQL'
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  updated_at INTEGER,
  cwd TEXT DEFAULT '',
  archived INTEGER DEFAULT 0,
  thread_source TEXT,
  agent_nickname TEXT,
  agent_role TEXT,
  agent_path TEXT,
  title TEXT,
  rollout_path TEXT
);
SQL
}
write_unread_state() {
  "$PYTHON_BIN" - "$TASK_GLOBAL" "$@" <<'PY'
import json, sys
path = sys.argv[1]
thread_ids = sys.argv[2:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"electron-persisted-atom-state": {"unread-thread-ids-by-host-v1": {"local": thread_ids}}}, f)
PY
}
write_unread_state_with_active_root() {
  "$PYTHON_BIN" - "$TASK_GLOBAL" "$1" "$2" <<'PY'
import json, sys
path, root, thread_id = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"active-workspace-roots": [root], "electron-persisted-atom-state": {"unread-thread-ids-by-host-v1": {"local": [thread_id]}}}, f)
PY
}
write_unread_state_with_host() {
  "$PYTHON_BIN" - "$TASK_GLOBAL" "$1" "$2" <<'PY'
import json, sys
path, host, thread_id = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"electron-persisted-atom-state": {"unread-thread-ids-by-host-v1": {host: [thread_id]}}}, f)
PY
}
assert_task_light() {
  local expected="$1"
  local actual
  actual="$(CODEX_HOME="$CODEX_HOME" CODEX_AC_HOME="$CODEX_AC_HOME" CODEX_BALANCE_STATE_DIR="$CODEX_BALANCE_STATE_DIR" "$BALANCE_BIN" --task-light-once | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected task light '$expected', got '$actual'" >&2
    exit 1
  fi
}

write_task_db
write_unread_state missing-unread
assert_task_light idle

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('archived-unread', $TASK_NOW, 1, 'subagent', 'worker1', 'worker', '', 'archived unread', '');"
write_unread_state archived-unread
assert_task_light idle

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('sub-unread', $TASK_NOW, 0, 'subagent', 'worker1', 'worker', '', 'worker unread', '');"
write_unread_state sub-unread
assert_task_light idle

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('user-unread', $TASK_NOW, 0, 'user', '', '', '', 'user unread', '');"
write_unread_state user-unread
assert_task_light unread

write_task_db
TASK_OLD=$((TASK_NOW - 180))
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('stale-user-unread', $TASK_OLD, 0, 'user', '', '', '', 'stale user unread', '');"
write_unread_state stale-user-unread
assert_task_light unread

write_task_db
TASK_OLD=$((TASK_NOW - 172800))
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('stale-user-unread', $TASK_OLD, 0, 'user', '', '', '', 'stale user unread', '');"
write_unread_state stale-user-unread
assert_task_light idle

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('app-current-thread', $TASK_NOW, 0, 'user', '', '', '', 'app current thread', '');"
write_unread_state
assert_task_light idle

write_task_db
TASK_RECENT=$((TASK_NOW - 1800))
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('app-thread-a', $TASK_NOW, 0, 'user', '', '', '', 'app thread a', '');"
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('app-thread-b', $TASK_RECENT, 0, 'user', '', '', '', 'app thread b', '');"
write_unread_state
assert_task_light idle

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, cwd, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('other-workspace-unread', $TASK_NOW, '/tmp/other-project', 0, 'user', '', '', '', 'other workspace unread', '');"
write_unread_state_with_active_root /tmp/current-project other-workspace-unread
assert_task_light unread

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, cwd, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('current-workspace-unread', $TASK_NOW, '/tmp/current-project/app', 0, 'user', '', '', '', 'current workspace unread', '');"
write_unread_state_with_active_root /tmp/current-project current-workspace-unread
assert_task_light unread

write_task_db
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('host-unread', $TASK_NOW, 0, 'user', '', '', '', 'host unread', '');"
write_unread_state_with_host "$HOSTNAME" host-unread
assert_task_light unread

write_task_db
TASK_ROLLOUT="$TMP/open-turn.jsonl"
printf '%s\n' '{"type":"turn_context"}' > "$TASK_ROLLOUT"
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('worker-running', $TASK_NOW, 0, 'subagent', 'worker1', 'worker', '', 'worker running', '$TASK_ROLLOUT');"
write_unread_state
assert_task_light running

write_task_db
TASK_ROLLOUT="$TMP/open-turn-plus-unread.jsonl"
printf '%s\n' '{"type":"turn_context"}' > "$TASK_ROLLOUT"
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('worker-running', $TASK_NOW, 0, 'subagent', 'worker1', 'worker', '', 'worker running', '$TASK_ROLLOUT');"
/usr/bin/sqlite3 "$TASK_DB" "INSERT INTO threads(id, updated_at, archived, thread_source, agent_nickname, agent_role, agent_path, title, rollout_path) VALUES('user-unread', $TASK_NOW, 0, 'user', '', '', '', 'user unread', '');"
write_unread_state user-unread
assert_task_light unread+running

run_ca s fox --skip-expiry-check --no-backup >/dev/null
[[ "$(run_ca current)" == "fox" ]]
assert_not_contains "$CODEX_HOME/config.toml" 'model_provider = "relay"'
assert_not_contains "$CODEX_HOME/config.toml" '[model_providers.relay]'
assert_not_contains "$CODEX_HOME/config.toml" '127.0.0.1:'
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
