#!/usr/bin/env python3
"""Synthetic account-level token totals; never uses real Codex state or networking."""
import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "codex-auth/lib/codex-ac.py"
spec = importlib.util.spec_from_file_location("ca_tokens", SOURCE)
ca = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ca)
checks = 0


def expect(value, text):
    global checks
    checks += 1
    assert value, text


for raw, rendered in [(0, "0"), (9999, "9999"), (10000, "1万"), (15000, "1.5万"),
                      (100000000, "1亿"), (105062499332, "1050.6亿"), (8650848703, "86.5亿"),
                      (None, "?"), (True, "?"), (-1, "?"), (1.2, "?"), ("10", "?")]:
    expect(ca.fmt_token_total(raw) == rendered, "compact total formatting")

state = {"responses": {}, "requests": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        account = self.headers.get("ChatGPT-Account-Id")
        expect(self.path == "/profile", "profile path")
        expect(self.headers.get("Authorization") == "Bearer test-" + account, "account token/header pairing")
        state["requests"].append(account)
        code, payload = state["responses"].get(account, (200, {"stats": {"lifetime_tokens": 105062499332, "peak_daily_tokens": 8650848703}, "profile": {"email": "discard@example.com"}}))
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="token-totals.", dir=os.environ.get("CODEX_AUTH_TEST_TMPDIR")) as temp:
        root = Path(temp)
        codex = root / "codex"
        ac = root / "accounts"
        (ac / "accounts").mkdir(parents=True)
        codex.mkdir()
        env = {**os.environ, "CODEX_AC_HOME": str(ac), "CODEX_HOME": str(codex), "NODE_ENV": "test",
               "CODEX_AC_TEST_PROFILE_URL": f"http://127.0.0.1:{server.server_port}/profile", "PYTHONDONTWRITEBYTECODE": "1"}
        registry = {"version": 1, "active_alias": "fox", "accounts": {}}
        for alias in ("fox", "other"):
            obj = {"email": alias + "@example.com", "auth_mode": "chatgpt", "chatgpt_account_id": alias,
                   "tokens": {"access_token": "test-" + alias, "account_id": alias}}
            p = ac / "accounts" / (alias + ".auth.json")
            p.write_text(json.dumps(obj))
            info = ca.auth_info(p)
            registry["accounts"][alias] = {"alias": alias, "auth_file": f"accounts/{alias}.auth.json", **info}
            if alias == "fox":
                (codex / "auth.json").write_bytes(p.read_bytes())
        registry["accounts"]["relay"] = {"kind": "api", "base_url": "https://relay.example.com/v1"}
        reg = ac / "registry.json"
        reg.write_text(json.dumps(registry))
        original_auth = (codex / "auth.json").read_bytes()
        originals = {p: p.read_bytes() for p in (ac / "accounts").iterdir()}

        def run(*args, success=True):
            result = subprocess.run([sys.executable, str(SOURCE), "tokens", *args], env=env, capture_output=True, text=True, timeout=30)
            expect((result.returncode == 0) == success, "command exit")
            expect("test-fox" not in result.stdout + result.stderr and "test-other" not in result.stdout + result.stderr, "no tokens in output")
            return result

        blank = run("--cached")
        expect("TOTAL TOKENS" in blank.stdout and "PEAK/DAY" in blank.stdout, "clear total versus daily peak headers")
        expect(not state["requests"], "empty cache performs no request")
        expect(blank.stdout.rstrip().endswith("Total tokens: ?"), "unknown totals are not summed as zero")
        state["responses"]["other"] = (200, {"stats": {"lifetime_tokens": 0, "peak_daily_tokens": None}})
        live = run()
        expect(set(state["requests"]) == {"fox", "other"} and len(state["requests"]) == 2, "query every ChatGPT snapshot but never API profiles")
        expect("1050.6亿" in live.stdout and "86.5亿" in live.stdout and "relay" in live.stdout, "compact server statistics and API row")
        expect(live.stdout.rstrip().endswith("Total tokens: 1050.6亿"), "one final total excludes API profiles")
        expect(live.stdout.count("Total tokens:") == 1, "aggregate occupies one line")
        cached = json.loads(reg.read_text())
        expect(cached["accounts"]["fox"]["token_totals"] == {"lifetime_tokens": 105062499332, "peak_daily_tokens": 8650848703}, "only normalized service totals persisted")
        expect(cached["accounts"]["other"]["token_totals"] == {"lifetime_tokens": 0, "peak_daily_tokens": None}, "zero and unknown are distinct")
        expect("discard@example.com" not in reg.read_text(), "profile identity/details not cached")
        data = reg.read_bytes()
        prior_requests = len(state["requests"])
        one = run("fox", "fox", "--cached")
        expect("other" not in one.stdout and "relay" not in one.stdout and one.stdout.count("1050.6亿") == 2, "one selected detail row plus its aggregate; duplicate aliases never add a second row")
        expect(reg.read_bytes() == data and len(state["requests"]) == prior_requests, "cached path has no registry write or request")
        run("does-not-exist", success=False)
        expect(reg.read_bytes() == data and len(state["requests"]) == prior_requests, "bad alias fails before network/cache changes")
        expect(run("other", "--cached").stdout.rstrip().endswith("Total tokens: 0"), "known zero aggregate")
        expect(run("relay", "--cached").stdout.rstrip().endswith("Total tokens: -"), "API-only aggregate is not applicable")
        partial = json.loads(data)
        partial["accounts"]["other"]["token_totals"]["lifetime_tokens"] = None
        reg.write_text(json.dumps(partial))
        expect(run("--cached").stdout.rstrip().endswith("Total tokens: ?"), "one unknown account keeps the aggregate unknown")
        rounding = json.loads(data)
        for alias in ("fox", "other"):
            rounding["accounts"][alias]["token_totals"]["lifetime_tokens"] = 14400
        reg.write_text(json.dumps(rounding))
        expect(run("--cached").stdout.rstrip().endswith("Total tokens: 2.9万"), "sum raw integers before rounding, not 1.4万 plus 1.4万")
        duplicates = json.loads(data)
        duplicate = dict(duplicates["accounts"]["fox"], alias="copy",
                         token_totals={"lifetime_tokens": 200000000000, "peak_daily_tokens": None})
        duplicate["last_token_totals_at"] -= 1
        duplicates["accounts"]["copy"] = duplicate
        reg.write_text(json.dumps(duplicates))
        expect(run("--cached").stdout.rstrip().endswith("Total tokens: 1050.6亿"), "same account under multiple aliases is counted once using the fresher snapshot")
        duplicate["last_token_totals_at"] += 2
        reg.write_text(json.dumps(duplicates))
        expect(run("--cached").stdout.rstrip().endswith("Total tokens: 2000亿"), "newer duplicate snapshot supplies the aggregate")
        duplicate["last_token_totals_at"] -= 1
        duplicate["last_token_totals_error"] = "503"
        reg.write_text(json.dumps(duplicates))
        expect(run("--cached").stdout.rstrip().endswith("Total tokens: 1050.6亿"), "equal-age successful identity snapshot wins over a failed alias")
        reg.write_bytes(data)
        for payload in [b"invalid JSON", [], {}, {"stats": []}, {"stats": {"lifetime_tokens": True}},
                        {"stats": {"lifetime_tokens": -1}}, {"stats": {"lifetime_tokens": "10"}},
                        {"stats": {"lifetime_tokens": 1.5}}, b"x" * (2 * 1024 * 1024 + 1)]:
            state["responses"]["fox"] = (200, payload)
            result = run("fox")
            failed = json.loads(reg.read_text())["accounts"]["fox"]
            expect(failed["token_totals"] == cached["accounts"]["fox"]["token_totals"], "malformed service response preserves successful totals")
            expect(failed["last_token_totals_at"] == cached["accounts"]["fox"]["last_token_totals_at"], "failed refresh does not advance UPDATED")
            expect("!" in result.stdout and "warning:" in result.stderr, "failed refresh visibly marked")
        state["responses"]["fox"] = (503, {})
        failed = run("fox")
        expect("1050.6亿" in failed.stdout and "503" in failed.stderr, "HTTP failure preserves cached success")
        expect(failed.stdout.rstrip().endswith("Total tokens: 1050.6亿 !"), "aggregate using a failed-refresh cache is visibly marked")
        expect("!" in run("fox", "--cached").stdout, "cached error marker is not silently lost")
        state["responses"]["fox"] = (200, {"stats": None})
        run("fox")
        record = json.loads(reg.read_text())["accounts"]["fox"]
        expect(record["token_totals"] == {"lifetime_tokens": None, "peak_daily_tokens": None} and "last_token_totals_error" not in record, "successful unavailable metrics are unknown and clear old errors")
        identity = originals[ac / "accounts/fox.auth.json"]
        (ac / "accounts/fox.auth.json").write_bytes(originals[ac / "accounts/other.auth.json"])
        count = len(state["requests"])
        mismatch = run("fox")
        expect("账号身份不匹配" in mismatch.stderr and len(state["requests"]) == count, "mismatched saved identity fails before networking")
        (ac / "accounts/fox.auth.json").write_bytes(identity)
        expect((codex / "auth.json").read_bytes() == original_auth, "active Codex login unchanged")
        expect(all(p.read_bytes() == data for p, data in originals.items()), "all saved auth snapshots unchanged")
        ca.import_auth("fox", ac / "accounts/fox.auth.json", "codex-auth", force=True, ac_home=ac)
        expect("token_totals" in json.loads(reg.read_text())["accounts"]["fox"], "same-account reimport keeps totals")
        ca.import_auth("fox", ac / "accounts/other.auth.json", "codex-auth", force=True, ac_home=ac)
        expect("token_totals" not in json.loads(reg.read_text())["accounts"]["fox"], "replacing alias with another identity never carries old totals")
        reg.write_text(json.dumps({"version": 1, "accounts": {}}))
        expect("暂无账号" in run().stdout, "empty account store")
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
print(f"token-totals: {checks} assertions passed")
