#!/usr/bin/env python3
from __future__ import annotations

import base64
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CA_PY = ROOT / "codex-auth" / "lib" / "codex-ac.py"
INSTALLER = ROOT / "scripts" / "install-codex-auth.sh"
UNINSTALLER = ROOT / "scripts" / "uninstall-codex-auth.sh"


def b64url(value: dict[str, Any]) -> str:
    raw = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def jwt(payload: dict[str, Any]) -> str:
    return f"{b64url({'alg': 'none', 'typ': 'JWT'})}.{b64url(payload)}.sig"


def make_auth(
    user: str,
    account: str,
    email: str,
    *,
    expires_at: int,
    refresh_token: str,
    access_label: str,
) -> dict[str, Any]:
    auth_claims = {
        "chatgpt_user_id": user,
        "chatgpt_account_id": account,
        "chatgpt_plan_type": "pro",
    }
    access = jwt({"sub": user, "exp": expires_at, "https://api.openai.com/auth": auth_claims})
    identity = jwt({"sub": user, "email": email, "https://api.openai.com/auth": auth_claims})
    return {
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": None,
        "tokens": {
            "id_token": identity,
            "access_token": access,
            "refresh_token": refresh_token,
            "account_id": account,
            "test_access_label": access_label,
        },
        "last_refresh": "2026-07-01T00:00:00Z",
    }


def write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    path.chmod(mode)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_path(codex_home: Path, account_key: str) -> Path:
    name = base64.urlsafe_b64encode(account_key.encode()).decode().rstrip("=") + ".auth.json"
    return codex_home / "accounts" / name


def load_ca_module(codex_home: Path, ac_home: Path):
    os.environ["CODEX_HOME"] = str(codex_home)
    os.environ["CODEX_AC_HOME"] = str(ac_home)
    spec = importlib.util.spec_from_file_location("codex_ac_keepalive_test", CA_PY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RefreshServer:
    def __init__(self, now: int):
        self.now = now
        self.requests: list[dict[str, Any]] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("content-length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
                owner.requests.append(body)
                token = body.get("refresh_token")
                if token == "due-old-refresh":
                    response = make_auth(
                        "user-due",
                        "account-due",
                        "due@example.test",
                        expires_at=owner.now + 10 * 86400,
                        refresh_token="due-new-refresh",
                        access_label="due-new-access",
                    )["tokens"]
                    payload = {
                        "access_token": response["access_token"],
                        "refresh_token": response["refresh_token"],
                        "id_token": response["id_token"],
                    }
                    self._send(200, payload)
                    return
                if token == "expired-old-refresh":
                    response = make_auth(
                        "user-expired",
                        "account-expired",
                        "expired@example.test",
                        expires_at=owner.now + 10 * 86400,
                        refresh_token="expired-new-refresh",
                        access_label="expired-new-access",
                    )["tokens"]
                    self._send(
                        200,
                        {
                            "access_token": response["access_token"],
                            "refresh_token": response["refresh_token"],
                            "id_token": response["id_token"],
                        },
                    )
                    return
                if token == "reused-old-refresh":
                    self._send(
                        401,
                        {
                            "error": {
                                "message": "The refresh token was already used.",
                                "code": "refresh_token_reused",
                            }
                        },
                    )
                    return
                if token == "mismatch-old-refresh":
                    response = make_auth(
                        "user-other",
                        "account-other",
                        "other@example.test",
                        expires_at=owner.now + 10 * 86400,
                        refresh_token="mismatch-new-refresh",
                        access_label="mismatch-new-access",
                    )["tokens"]
                    self._send(
                        200,
                        {
                            "access_token": response["access_token"],
                            "refresh_token": response["refresh_token"],
                            "id_token": response["id_token"],
                        },
                    )
                    return
                self._send(500, {"error": {"message": "unexpected test refresh token"}})

            def _send(self, status: int, payload: dict[str, Any]) -> None:
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_: Any) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}/oauth/token"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def run_ca(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CA_PY), *args],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )


def assert_no_token_output(result: subprocess.CompletedProcess[str]) -> None:
    output = result.stdout + result.stderr
    for secret in [
        "due-old-refresh",
        "due-new-refresh",
        "expired-old-refresh",
        "expired-new-refresh",
        "reused-old-refresh",
        "mismatch-old-refresh",
        "active-current-refresh",
        "fresh-old-refresh",
    ]:
        assert secret not in output, output


def test_keepalive(codex_bin: str, root: Path) -> None:
    now = int(time.time())
    codex_home = root / "codex-home"
    ac_home = root / "codex-ac"
    sources = root / "sources"
    codex_home.mkdir(parents=True)
    ac_home.mkdir(parents=True)
    module = load_ca_module(codex_home, ac_home)

    definitions = {
        "active": make_auth(
            "user-active",
            "account-active",
            "active@example.test",
            expires_at=now + 3600,
            refresh_token="active-saved-refresh",
            access_label="active-saved-access",
        ),
        "due": make_auth(
            "user-due",
            "account-due",
            "due@example.test",
            expires_at=now + 3600,
            refresh_token="due-old-refresh",
            access_label="due-old-access",
        ),
        "fresh": make_auth(
            "user-fresh",
            "account-fresh",
            "fresh@example.test",
            expires_at=now + 8 * 86400,
            refresh_token="fresh-old-refresh",
            access_label="fresh-old-access",
        ),
        "expired": make_auth(
            "user-expired",
            "account-expired",
            "expired@example.test",
            expires_at=now - 3600,
            refresh_token="expired-old-refresh",
            access_label="expired-old-access",
        ),
        "reused": make_auth(
            "user-reused",
            "account-reused",
            "reused@example.test",
            expires_at=now - 3600,
            refresh_token="reused-old-refresh",
            access_label="reused-old-access",
        ),
        "mismatch": make_auth(
            "user-mismatch",
            "account-mismatch",
            "mismatch@example.test",
            expires_at=now + 3600,
            refresh_token="mismatch-old-refresh",
            access_label="mismatch-old-access",
        ),
    }
    active_current = make_auth(
        "user-active",
        "account-active",
        "active@example.test",
        expires_at=now + 10 * 86400,
        refresh_token="active-current-refresh",
        access_label="active-current-access",
    )
    write_json(codex_home / "auth.json", active_current)

    for alias, auth in definitions.items():
        source = sources / f"{alias}.json"
        write_json(source, auth)
        module.import_auth(alias, source, "codex-auth", force=True)

    registry = module.load_registry()
    registry["active_alias"] = "active"
    registry["accounts"]["relay"] = {
        "alias": "relay",
        "kind": "api",
        "base_url": "https://relay.example.test/v1",
        "created_at": module.now_iso(),
        "updated_at": module.now_iso(),
    }
    module.save_registry(registry)

    native_records = []
    native_paths: dict[str, Path] = {}
    for alias, auth in definitions.items():
        user = auth["tokens"]["id_token"].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(user + "=" * (-len(user) % 4)))
        namespace = claims["https://api.openai.com/auth"]
        key = f"{namespace['chatgpt_user_id']}::{namespace['chatgpt_account_id']}"
        path = native_path(codex_home, key)
        write_json(path, auth)
        native_paths[alias] = path
        native_records.append(
            {
                "account_key": key,
                "chatgpt_user_id": namespace["chatgpt_user_id"],
                "chatgpt_account_id": namespace["chatgpt_account_id"],
                "alias": alias,
                "auth_mode": "chatgpt",
            }
        )
    write_json(
        codex_home / "accounts" / "registry.json",
        {"schema_version": 1, "active_account_key": native_records[0]["account_key"], "accounts": native_records},
    )

    env = os.environ.copy()
    env.update(
        {
            "CODEX_HOME": str(codex_home),
            "CODEX_AC_HOME": str(ac_home),
            "CODEX_BIN": codex_bin,
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )

    with RefreshServer(now) as server:
        env["CODEX_REFRESH_TOKEN_URL_OVERRIDE"] = server.url
        before_dry_run = {p: sha256(p) for p in [ac_home / "registry.json", *(ac_home / "accounts").glob("*.json"), *native_paths.values()]}
        dry_run = run_ca(env, "keepalive", "--dry-run")
        assert dry_run.returncode == 0, (dry_run.stdout, dry_run.stderr)
        assert len(server.requests) == 0
        assert before_dry_run == {p: sha256(p) for p in before_dry_run}
        assert "active: 当前账号由 Codex 维护" in dry_run.stdout
        assert "due: 需要续期" in dry_run.stdout
        assert "fresh: 凭证仍有效" in dry_run.stdout
        assert "relay: API 账号无需续期" in dry_run.stdout
        assert_no_token_output(dry_run)

        lock_path = ac_home / "account-store.lock"
        lock_path.touch()
        with lock_path.open("a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = run_ca(env, "keepalive", "--dry-run")
            assert locked.returncode == 0, (locked.stdout, locked.stderr)
            assert "本次跳过" in locked.stdout
        assert len(server.requests) == 0

        with lock_path.open("a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            list_process = subprocess.Popen(
                [sys.executable, str(CA_PY), "__list-ui", "--cached", "--no-color"],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            time.sleep(0.5)
            assert list_process.poll() is None, "list UI did not wait for the account lock"
        list_stdout, list_stderr = list_process.communicate(timeout=30)
        assert list_process.returncode == 0, (list_stdout, list_stderr)

        protected_before = {
            alias: (sha256(ac_home / "accounts" / f"{alias}.auth.json"), sha256(native_paths[alias]))
            for alias in ["fresh", "reused", "mismatch"]
        }
        current_before = sha256(codex_home / "auth.json")
        result = run_ca(env, "keepalive")
        assert result.returncode == 1, (result.stdout, result.stderr)
        assert_no_token_output(result)
        requested = [item.get("refresh_token") for item in server.requests]
        assert len(requested) == 4, requested
        assert sorted(requested) == sorted(
            ["due-old-refresh", "expired-old-refresh", "reused-old-refresh", "mismatch-old-refresh"]
        ), requested

    assert sha256(codex_home / "auth.json") == current_before
    due_saved = read_json(ac_home / "accounts" / "due.auth.json")
    due_native = read_json(native_paths["due"])
    assert due_saved["tokens"]["refresh_token"] == "due-new-refresh"
    assert due_native["tokens"]["refresh_token"] == "due-new-refresh"
    expired_saved = read_json(ac_home / "accounts" / "expired.auth.json")
    expired_native = read_json(native_paths["expired"])
    assert expired_saved["tokens"]["refresh_token"] == "expired-new-refresh"
    assert expired_native["tokens"]["refresh_token"] == "expired-new-refresh"
    assert read_json(ac_home / "accounts" / "active.auth.json") == active_current
    assert read_json(native_paths["active"]) == active_current
    assert protected_before["fresh"] == (
        sha256(ac_home / "accounts" / "fresh.auth.json"),
        sha256(native_paths["fresh"]),
    )
    assert protected_before["reused"] == (
        sha256(ac_home / "accounts" / "reused.auth.json"),
        sha256(native_paths["reused"]),
    )
    assert protected_before["mismatch"] == (
        sha256(ac_home / "accounts" / "mismatch.auth.json"),
        sha256(native_paths["mismatch"]),
    )
    registry = read_json(ac_home / "registry.json")
    assert registry["accounts"]["active"]["last_keepalive_status"] == "active"
    assert registry["accounts"]["due"]["last_keepalive_status"] == "renewed"
    assert registry["accounts"]["expired"]["last_keepalive_status"] == "renewed"
    assert registry["accounts"]["fresh"]["last_keepalive_status"] == "fresh"
    assert registry["accounts"]["reused"]["last_keepalive_status"] == "needs_login"
    assert registry["accounts"]["reused"]["last_keepalive_error"] == "refresh_token_reused"
    assert registry["accounts"]["mismatch"]["last_keepalive_status"] == "needs_login"


def test_installer(codex_bin: str, root: Path) -> None:
    home = root / "install-home"
    prefix = home / ".local"
    home.mkdir(parents=True)
    marker = home / ".codex-ac" / "accounts" / "preserved.marker"
    marker.parent.mkdir(parents=True)
    marker.write_text("preserve", encoding="utf-8")
    label = "com.codexlocaltools.codex-auth-keepalive.test"
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "PREFIX": str(prefix),
            "CODEX_BIN": codex_bin,
            "CODEX_AUTH_KEEPALIVE_LABEL": label,
            "CODEX_AUTH_KEEPALIVE_NO_START": "1",
        }
    )
    installed = subprocess.run(
        ["/bin/bash", str(INSTALLER), "--no-start"],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    assert installed.returncode == 0, (installed.stdout, installed.stderr)
    plist_path = home / "Library" / "LaunchAgents" / f"{label}.plist"
    payload = plistlib.loads(plist_path.read_bytes())
    assert payload["StartInterval"] == 86400
    assert payload["RunAtLoad"] is True
    assert payload["ProgramArguments"] == [str(prefix / "bin" / "codex-ac"), "keepalive", "--quiet"]
    assert payload["EnvironmentVariables"]["CODEX_BIN"] == codex_bin
    node_bin = shutil.which("node")
    if node_bin:
        assert str(Path(node_bin).parent) in payload["EnvironmentVariables"]["PATH"].split(":")
    version = subprocess.run(
        [str(prefix / "bin" / "codex-ac"), "--version"],
        env={**env, "CODEX_AC_LIB": str(prefix / "lib" / "codex-ac")},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    assert version.returncode == 0, (version.stdout, version.stderr)
    assert version.stdout.strip() == "codex-ac 0.8.1"

    removed = subprocess.run(
        ["/bin/bash", str(UNINSTALLER)],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    assert removed.returncode == 0, (removed.stdout, removed.stderr)
    assert not plist_path.exists()
    assert not (prefix / "bin" / "codex-ac").exists()
    assert marker.read_text(encoding="utf-8") == "preserve"


def main() -> int:
    codex_bin = os.environ.get("CODEX_BIN") or shutil.which("codex")
    if not codex_bin:
        print("codex is required for keepalive integration tests", file=sys.stderr)
        return 2
    scratch_parent = Path("/Volumes/E82/CodexTempScratch")
    temp_parent = scratch_parent if scratch_parent.is_dir() else None
    with tempfile.TemporaryDirectory(prefix="codex-auth-keepalive-test.", dir=temp_parent) as tmp:
        root = Path(tmp)
        test_keepalive(codex_bin, root)
        test_installer(codex_bin, root)
    print("keepalive auth integration test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
