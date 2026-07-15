#!/usr/bin/env python3
# codex-ac: local Codex account manager
# v0.1 - manages local auth snapshots without logging tokens.

from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as _dt
import fcntl
import getpass
import hashlib
import json
import os
import re
import select
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

VERSION = "0.8.0"
DEFAULT_AC_HOME = Path(os.environ.get("CODEX_AC_HOME", str(Path.home() / ".codex-ac"))).expanduser()
DEFAULT_CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RESERVED = set()
KEEPALIVE_THRESHOLD_SECONDS = 3 * 24 * 60 * 60
KEEPALIVE_REFRESH_TIMEOUT_SECONDS = 45


class AccountStoreBusy(RuntimeError):
    pass


class KeepaliveRefreshError(RuntimeError):
    def __init__(self, code: str, *, permanent: bool = False):
        super().__init__(code)
        self.code = code
        self.permanent = permanent


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def now_stamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def ensure_dirs(ac_home: Path = DEFAULT_AC_HOME) -> None:
    for p in [ac_home, ac_home / "accounts", ac_home / "backups", ac_home / "homes", ac_home / "tmp"]:
        p.mkdir(parents=True, exist_ok=True)
        try:
            p.chmod(0o700)
        except OSError:
            pass


@contextlib.contextmanager
def account_store_lock(*, nonblocking: bool = False):
    ensure_dirs()
    lock_path = DEFAULT_AC_HOME / "account-store.lock"
    with lock_path.open("a+") as lock_file:
        try:
            mode = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
            fcntl.flock(lock_file.fileno(), mode)
        except BlockingIOError as exc:
            raise AccountStoreBusy("账号库正被另一个 ca 操作使用") from exc
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def registry_path(ac_home: Path = DEFAULT_AC_HOME) -> Path:
    return ac_home / "registry.json"


def load_registry(ac_home: Path = DEFAULT_AC_HOME) -> Dict[str, Any]:
    ensure_dirs(ac_home)
    p = registry_path(ac_home)
    if not p.exists():
        return {"version": 1, "active_alias": None, "accounts": {}, "created_at": now_iso(), "updated_at": now_iso()}
    with p.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data.get("accounts"), dict):
        data["accounts"] = {}
    data.setdefault("version", 1)
    data.setdefault("active_alias", None)
    return data


def save_registry(reg: Dict[str, Any], ac_home: Path = DEFAULT_AC_HOME) -> None:
    ensure_dirs(ac_home)
    reg["updated_at"] = now_iso()
    p = registry_path(ac_home)
    tmp = p.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(reg, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    try:
        tmp.chmod(0o600)
    except OSError:
        pass
    os.replace(tmp, p)
    try:
        p.chmod(0o600)
    except OSError:
        pass


def validate_alias(alias: str) -> str:
    if not ALIAS_RE.match(alias):
        raise SystemExit(f"别名不合法：{alias!r}。只能用字母数字开头，后续支持 . _ -，长度 1-64。")
    if alias in RESERVED:
        raise SystemExit(f"别名 {alias!r} 是保留字，请换一个。")
    return alias


def alias_auth_path(alias: str, ac_home: Path = DEFAULT_AC_HOME) -> Path:
    return ac_home / "accounts" / f"{alias}.auth.json"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def b64url_decode_to_json(segment: str) -> Optional[Dict[str, Any]]:
    try:
        segment += "=" * ((4 - len(segment) % 4) % 4)
        return json.loads(base64.urlsafe_b64decode(segment.encode("utf-8")))
    except Exception:
        return None


def decode_jwt_payload(token: Optional[str]) -> Optional[Dict[str, Any]]:
    if not token or token.count(".") < 2:
        return None
    return b64url_decode_to_json(token.split(".")[1])


def read_auth(path: Path) -> Tuple[Dict[str, Any], bytes]:
    data = path.read_bytes()
    try:
        obj = json.loads(data.decode("utf-8"))
    except Exception as exc:
        raise SystemExit(f"无法解析 auth JSON：{path}：{exc}")
    if not isinstance(obj, dict):
        raise SystemExit(f"auth JSON 顶层不是对象：{path}")
    return obj, data


def first_str(*values: Any) -> Optional[str]:
    for v in values:
        if isinstance(v, str) and v:
            return v
    return None


def auth_info(path: Path) -> Dict[str, Any]:
    obj, data = read_auth(path)
    tokens = obj.get("tokens") if isinstance(obj.get("tokens"), dict) else {}
    payload = decode_jwt_payload(tokens.get("id_token") if isinstance(tokens, dict) else None) or {}
    auth_ns = payload.get("https://api.openai.com/auth") if isinstance(payload.get("https://api.openai.com/auth"), dict) else {}

    email = first_str(obj.get("email"), payload.get("email"))
    user_id = first_str(auth_ns.get("chatgpt_user_id"), auth_ns.get("user_id"), payload.get("sub"))
    account_id = first_str(auth_ns.get("chatgpt_account_id"), obj.get("chatgpt_account_id"))
    plan = first_str(auth_ns.get("chatgpt_plan_type"), obj.get("plan"))
    auth_mode = first_str(obj.get("auth_mode"))
    name = first_str(payload.get("name"))

    if user_id and account_id:
        identity = f"{user_id}::{account_id}"
    elif user_id:
        identity = user_id
    elif email:
        identity = email.lower()
    else:
        identity = "sha256:" + sha256_bytes(data)

    return {
        "email": email,
        "email_masked": mask_email(email),
        "name": name,
        "plan": plan,
        "auth_mode": auth_mode,
        "chatgpt_user_id": user_id,
        "chatgpt_account_id": account_id,
        "identity_hash": hashlib.sha256(identity.encode("utf-8")).hexdigest(),
        "auth_sha256": sha256_bytes(data),
        "last_refresh": obj.get("last_refresh"),
    }


def mask_email(email: Optional[str]) -> str:
    if not email or "@" not in email:
        return "<unknown>"
    local, domain = email.split("@", 1)
    if len(local) <= 2:
        local_m = local[0] + "*" if local else "*"
    else:
        local_m = local[0] + "***" + local[-1]
    return local_m + "@" + domain


def copy_private(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + f".tmp.{os.getpid()}")
    try:
        with src.open("rb") as fsrc, tmp.open("wb") as fdst:
            shutil.copyfileobj(fsrc, fdst)
            fdst.flush()
            os.fsync(fdst.fileno())
        try:
            tmp.chmod(0o600)
        except OSError:
            pass
        os.replace(tmp, dst)
        try:
            dst.chmod(0o600)
        except OSError:
            pass
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def write_private(data: bytes, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + f".tmp.{os.getpid()}")
    try:
        with tmp.open("wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        try:
            tmp.chmod(0o600)
        except OSError:
            pass
        os.replace(tmp, dst)
        try:
            dst.chmod(0o600)
        except OSError:
            pass
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def import_auth(alias: str, auth_path: Path, source: str, force: bool = False, ac_home: Path = DEFAULT_AC_HOME) -> str:
    alias = validate_alias(alias)
    auth_path = auth_path.expanduser().resolve()
    if not auth_path.exists() or auth_path.stat().st_size == 0:
        raise SystemExit(f"auth 文件不存在或为空：{auth_path}")
    info = auth_info(auth_path)
    reg = load_registry(ac_home)
    existed = alias in reg["accounts"]
    if existed and not force:
        raise SystemExit(f"别名已存在：{alias}。如需覆盖，加 --force。")
    dst = alias_auth_path(alias, ac_home)
    copy_private(auth_path, dst)
    old = reg["accounts"].get(alias, {}) if existed else {}
    rec = {
        "alias": alias,
        "auth_file": str(dst.relative_to(ac_home)),
        "email": info.get("email"),
        "email_masked": info.get("email_masked"),
        "name": info.get("name"),
        "plan": info.get("plan"),
        "auth_mode": info.get("auth_mode"),
        "chatgpt_user_id": info.get("chatgpt_user_id"),
        "chatgpt_account_id": info.get("chatgpt_account_id"),
        "identity_hash": info.get("identity_hash"),
        "auth_sha256": info.get("auth_sha256"),
        "source": source,
        "created_at": old.get("created_at") or now_iso(),
        "updated_at": now_iso(),
        "last_switched_at": old.get("last_switched_at"),
    }
    # 保留已有 usage 快照；迁移或 refresh 会再覆盖。
    for k in [
        "last_usage",
        "last_usage_at",
        "last_usage_error",
        "last_local_rollout",
        "last_used_at",
        "last_keepalive_check_at",
        "last_keepalive_at",
        "last_keepalive_status",
        "last_keepalive_error",
    ]:
        if k in old:
            rec[k] = old[k]
    reg["accounts"][alias] = rec
    # 同步进 codex-auth 原生 registry：usage/list 继续沿用它的成熟处理。
    if source != "codex-auth":
        try:
            subprocess.run(["codex-auth", "import", str(auth_path), "--alias", alias], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        except Exception:
            pass
    if reg.get("active_alias") is None:
        # 只在首次初始化时设置元数据 active，不写 ~/.codex/auth.json。
        reg["active_alias"] = detect_current_alias(reg, DEFAULT_CODEX_HOME) or alias
    save_registry(reg, ac_home)
    return "updated" if existed else "imported"


def detect_current_alias(reg: Dict[str, Any], codex_home: Path = DEFAULT_CODEX_HOME) -> Optional[str]:
    if codex_home == DEFAULT_CODEX_HOME:
        api_alias = detect_api_current_alias(reg)
        if api_alias:
            return api_alias
    auth = codex_home / "auth.json"
    if not auth.exists():
        return None
    try:
        info = auth_info(auth)
    except SystemExit:
        return None
    cur_ident = info.get("identity_hash")
    cur_sha = info.get("auth_sha256")
    for alias, rec in reg.get("accounts", {}).items():
        if rec.get("identity_hash") and rec.get("identity_hash") == cur_ident:
            return alias
    for alias, rec in reg.get("accounts", {}).items():
        if rec.get("auth_sha256") and rec.get("auth_sha256") == cur_sha:
            return alias
    return None


def account_auth_file(alias: str, reg: Dict[str, Any], ac_home: Path = DEFAULT_AC_HOME) -> Path:
    rec = reg.get("accounts", {}).get(alias)
    if not rec:
        raise SystemExit(f"账号别名不存在：{alias}")
    rel = rec.get("auth_file")
    p = (ac_home / rel).resolve() if rel else alias_auth_path(alias, ac_home)
    if not p.exists():
        raise SystemExit(f"账号 auth 快照缺失：{p}")
    return p


def _as_int(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return None


def _local_dt(ts: int) -> _dt.datetime:
    return _dt.datetime.fromtimestamp(ts).astimezone()


def fmt_reset_parts(ts: Optional[int]) -> Tuple[str, str, bool]:
    if not ts:
        return "-", "-", True
    dt = _local_dt(ts)
    now = _dt.datetime.now().astimezone()
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return dt.strftime("%H:%M"), f"{dt.day} {months[dt.month - 1]}", dt.date() == now.date()


def fmt_last_activity(ts: Optional[int]) -> str:
    if not ts or ts <= 0:
        return "-"
    delta = int(time.time()) - ts
    if delta < 0:
        delta = 0
    if delta < 60:
        return "Now"
    if delta < 3600:
        return f"{delta // 60}m ago"
    if delta < 86400:
        return f"{delta // 3600}h ago"
    return f"{delta // 86400}d ago"


def window_matches_minutes(win: Optional[Dict[str, Any]], expected_minutes: int) -> bool:
    if not isinstance(win, dict):
        return False
    actual_minutes = _as_int(win.get("window_minutes"))
    if actual_minutes is None:
        return False
    return abs(actual_minutes - expected_minutes) <= max(1, expected_minutes // 4)


def window_for(snapshot: Optional[Dict[str, Any]], minutes: int, fallback_primary: bool) -> Optional[Dict[str, Any]]:
    if not isinstance(snapshot, dict):
        return None
    primary = snapshot.get("primary") if isinstance(snapshot.get("primary"), dict) else None
    secondary = snapshot.get("secondary") if isinstance(snapshot.get("secondary"), dict) else None
    for win in [primary, secondary]:
        if window_matches_minutes(win, minutes):
            return win
    fallback = primary if fallback_primary else secondary
    if isinstance(fallback, dict) and _as_int(fallback.get("window_minutes")) is None:
        return fallback
    return None


def five_hour_is_unlimited(snapshot: Optional[Dict[str, Any]]) -> bool:
    if not isinstance(snapshot, dict) or window_for(snapshot, 300, True):
        return False
    return window_for(snapshot, 10080, False) is not None


def fmt_usage(snapshot: Optional[Dict[str, Any]], minutes: int, fallback_primary: bool, err: Optional[str] = None) -> str:
    if err and not snapshot:
        return err
    if minutes == 300 and five_hour_is_unlimited(snapshot):
        return "∞"
    win = window_for(snapshot, minutes, fallback_primary)
    if not win:
        return "-"
    used = win.get("used_percent")
    if not isinstance(used, (int, float)):
        return "-"
    reset = _as_int(win.get("resets_at"))
    now = int(time.time())
    if reset and reset <= now:
        return "100%"
    remaining = 100.0 - float(used)
    if remaining <= 0:
        pct = 0
    elif remaining >= 100:
        pct = 100
    else:
        pct = int(remaining)
    if not reset:
        return "-"
    tm, date, same_day = fmt_reset_parts(reset)
    return f"{pct}% ({tm})" if same_day else f"{pct}% ({tm} on {date})"


def parse_usage_api_response(body: bytes) -> Optional[Dict[str, Any]]:
    root = json.loads(body.decode("utf-8"))
    if not isinstance(root, dict):
        return None
    snap: Dict[str, Any] = {"primary": None, "secondary": None, "credits": None, "plan_type": root.get("plan_type")}
    credits = root.get("credits")
    if isinstance(credits, dict):
        snap["credits"] = {
            "has_credits": bool(credits.get("has_credits", False)),
            "unlimited": bool(credits.get("unlimited", False)),
            "balance": str(credits.get("balance")) if credits.get("balance") is not None else None,
        }
    rate_limit = root.get("rate_limit")
    if isinstance(rate_limit, dict):
        def parse_win(w: Any) -> Optional[Dict[str, Any]]:
            if not isinstance(w, dict) or not isinstance(w.get("used_percent"), (int, float)):
                return None
            seconds = _as_int(w.get("limit_window_seconds"))
            return {
                "used_percent": float(w.get("used_percent")),
                "window_minutes": ((seconds + 59) // 60) if seconds else None,
                "resets_at": _as_int(w.get("reset_at")),
            }
        snap["primary"] = parse_win(rate_limit.get("primary_window"))
        snap["secondary"] = parse_win(rate_limit.get("secondary_window"))
    if not snap.get("primary") and not snap.get("secondary"):
        return None
    return snap


def auth_api_context(path: Path) -> Tuple[str, str]:
    obj, _ = read_auth(path)
    tokens = obj.get("tokens") if isinstance(obj.get("tokens"), dict) else {}
    access_token = tokens.get("access_token") if isinstance(tokens, dict) else None
    info = auth_info(path)
    account_id = info.get("chatgpt_account_id")
    if not access_token or not account_id:
        raise RuntimeError("MissingAuth")
    return access_token, account_id


def fetch_usage_snapshot(auth_path: Path, timeout: int = 20) -> Tuple[Optional[Dict[str, Any]], str]:
    access_token, account_id = auth_api_context(auth_path)
    req = urllib.request.Request(
        "https://chatgpt.com/backend-api/wham/usage",
        method="GET",
        headers={
            "Authorization": f"Bearer {access_token}",
            "ChatGPT-Account-Id": account_id,
            "User-Agent": "Mozilla/5.0 codex-ac/0.2",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            status = getattr(resp, "status", 200)
    except urllib.error.HTTPError as exc:
        return None, str(exc.code)
    except Exception as exc:
        return None, exc.__class__.__name__
    if status < 200 or status >= 300:
        return None, str(status)
    try:
        snap = parse_usage_api_response(body)
    except Exception as exc:
        return None, exc.__class__.__name__
    return snap, str(status)


def refresh_aliases(reg: Dict[str, Any], aliases: list[str], *, verbose: bool = True) -> bool:
    changed = False
    accounts = reg.get("accounts", {})
    for alias in aliases:
        if alias not in accounts:
            raise SystemExit(f"账号别名不存在：{alias}")
        auth_path = account_auth_file(alias, reg)
        snap, status = fetch_usage_snapshot(auth_path)
        rec = accounts[alias]
        if snap:
            rec["last_usage"] = snap
            rec["last_usage_at"] = int(time.time())
            rec.pop("last_usage_error", None)
            if snap.get("plan_type"):
                rec["plan"] = snap.get("plan_type")
            changed = True
            if verbose:
                print(f"✓ {alias}: refreshed")
        else:
            rec["last_usage_error"] = status
            rec["last_usage_at"] = int(time.time())
            changed = True
            if verbose:
                print(f"! {alias}: {status}")
    return changed

def parse_iso_timestamp_ms(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    try:
        text = value.replace("Z", "+00:00")
        return int(_dt.datetime.fromisoformat(text).timestamp() * 1000)
    except Exception:
        return None


def newest_rollout_file() -> Optional[Path]:
    root = DEFAULT_CODEX_HOME / "sessions"
    if not root.exists():
        return None
    newest: Optional[Path] = None
    newest_mtime = -1.0
    for path in root.rglob("rollout-*.jsonl"):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if mtime > newest_mtime:
            newest = path
            newest_mtime = mtime
    return newest


def snapshot_from_local_rate_limits(rate_limits: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(rate_limits, dict):
        return None
    primary = rate_limits.get("primary") if isinstance(rate_limits.get("primary"), dict) else None
    secondary = rate_limits.get("secondary") if isinstance(rate_limits.get("secondary"), dict) else None
    if not primary and not secondary:
        return None
    return {
        "primary": primary,
        "secondary": secondary,
        "credits": rate_limits.get("credits") if isinstance(rate_limits.get("credits"), dict) else None,
        "plan_type": rate_limits.get("plan_type"),
    }


def newest_local_usage_event() -> Optional[Tuple[Path, int, Dict[str, Any]]]:
    path = newest_rollout_file()
    if not path:
        return None
    best_ms: Optional[int] = None
    best_snapshot: Optional[Dict[str, Any]] = None
    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None
                if not payload or payload.get("type") != "token_count":
                    continue
                event_ms = parse_iso_timestamp_ms(obj.get("timestamp"))
                snap = snapshot_from_local_rate_limits(payload.get("rate_limits"))
                if event_ms is not None and snap is not None:
                    best_ms = event_ms
                    best_snapshot = snap
    except OSError:
        return None
    if best_ms is None or best_snapshot is None:
        return None
    return path, best_ms, best_snapshot


def refresh_active_from_local_rollout(reg: Dict[str, Any]) -> bool:
    current = detect_current_alias(reg, DEFAULT_CODEX_HOME)
    alias = current or reg.get("active_alias")
    if not alias or alias not in reg.get("accounts", {}):
        return False
    event = newest_local_usage_event()
    if not event:
        return False
    path, event_ms, snapshot = event
    rec = reg["accounts"][alias]
    last = rec.get("last_local_rollout") if isinstance(rec.get("last_local_rollout"), dict) else {}
    if last.get("path") == str(path) and _as_int(last.get("event_timestamp_ms")) == event_ms:
        return False
    rec["last_usage"] = snapshot
    rec["last_usage_at"] = event_ms // 1000
    rec["last_local_rollout"] = {"path": str(path), "event_timestamp_ms": event_ms}
    rec.pop("last_usage_error", None)
    if snapshot.get("plan_type"):
        rec["plan"] = snapshot.get("plan_type")
    return True



def codex_auth_record_identity_hash(rec: Dict[str, Any]) -> Optional[str]:
    key = rec.get("account_key")
    if isinstance(key, str) and key:
        return hashlib.sha256(key.encode("utf-8")).hexdigest()
    user_id = rec.get("chatgpt_user_id")
    account_id = rec.get("chatgpt_account_id")
    if isinstance(user_id, str) and user_id and isinstance(account_id, str) and account_id:
        return hashlib.sha256(f"{user_id}::{account_id}".encode("utf-8")).hexdigest()
    return None


def run_codex_auth_native_refresh(api: bool) -> bool:
    exe = shutil.which("codex-auth")
    if not exe:
        return False
    cmd = [exe, "list"] if api else [exe, "list", "--skip-api"]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        return True
    except Exception:
        return False


def sync_usage_from_codex_auth_registry(reg: Dict[str, Any]) -> bool:
    p = DEFAULT_CODEX_HOME / "accounts" / "registry.json"
    if not p.exists():
        return False
    try:
        src = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return False
    records = src.get("accounts") or src.get("records") or []
    if not isinstance(records, list):
        return False
    by_hash: Dict[str, Dict[str, Any]] = {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        ident = codex_auth_record_identity_hash(rec)
        if ident:
            by_hash[ident] = rec
    changed = False
    for alias, dst in reg.get("accounts", {}).items():
        ident = dst.get("identity_hash")
        src_rec = by_hash.get(ident) if isinstance(ident, str) else None
        if not src_rec:
            # fallback: same ChatGPT user/account fields
            for rec in records:
                if not isinstance(rec, dict):
                    continue
                if rec.get("chatgpt_user_id") == dst.get("chatgpt_user_id") and rec.get("chatgpt_account_id") == dst.get("chatgpt_account_id"):
                    src_rec = rec
                    break
        if not src_rec:
            continue
        for k in ["last_usage", "last_usage_at", "last_local_rollout", "last_used_at"]:
            if src_rec.get(k) is not None and dst.get(k) != src_rec.get(k):
                dst[k] = src_rec.get(k)
                changed = True
        if src_rec.get("plan") and dst.get("plan") != src_rec.get("plan"):
            dst["plan"] = src_rec.get("plan")
            changed = True
        if dst.pop("last_usage_error", None) is not None:
            changed = True
    return changed


def sync_codex_auth_for_list(reg: Dict[str, Any], *, api: bool, cached: bool) -> bool:
    if cached:
        return False
    # usage 刷新交给 codex-auth native 实现，避免 Python 重写造成额度口径漂移。
    run_codex_auth_native_refresh(api=api)
    return sync_usage_from_codex_auth_registry(reg)


def cmd_refresh(args: argparse.Namespace) -> int:
    reg = load_registry()
    accounts = reg.get("accounts", {})
    if not accounts:
        print("暂无账号。")
        return 0
    if args.aliases:
        print("说明：codex-auth native 刷新不支持按别名子集刷新，本次会同步刷新全部账号。")
    ok = run_codex_auth_native_refresh(api=not args.skip_api)
    changed = sync_usage_from_codex_auth_registry(reg)
    if changed:
        save_registry(reg)
    print("refreshed via codex-auth" if ok else "codex-auth 不可用，仅保留缓存")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    reg = load_registry()
    accounts = reg.get("accounts", {})
    if not accounts:
        print("暂无账号。先执行：codex-ac add <alias> 或 codex-ac import-codex-auth")
        return 0
    api = bool(getattr(args, "api", False) or getattr(args, "refresh", False)) and not bool(getattr(args, "skip_api", False))
    changed = sync_codex_auth_for_list(reg, api=api, cached=bool(getattr(args, "cached", False)))
    if changed:
        save_registry(reg)
        reg = load_registry()
        accounts = reg.get("accounts", {})
    current = detect_current_alias(reg, DEFAULT_CODEX_HOME)
    active = current or reg.get("active_alias")
    rows = []
    for alias in sorted(accounts, key=lambda a: (0 if a == active else 1, a)):
        rec = accounts[alias]
        marker = "*" if alias == active else " "
        email = rec.get("email_masked") or mask_email(rec.get("email"))
        plan = (rec.get("plan") or "-").capitalize() if isinstance(rec.get("plan"), str) else "-"
        usage = rec.get("last_usage") if isinstance(rec.get("last_usage"), dict) else None
        err = rec.get("last_usage_error")
        h5 = fmt_usage(usage, 300, True, err)
        weekly = fmt_usage(usage, 10080, False, err)
        last = fmt_last_activity(_as_int(rec.get("last_usage_at")))
        rows.append((marker, alias, email, plan, h5, weekly, last))
    headers = ("ALIAS", "ACCOUNT", "PLAN", "5H USAGE", "WEEKLY USAGE", "LAST ACTIVITY")
    widths = [
        max(len(r[1]) for r in rows + [("", headers[0], "", "", "", "", "")]),
        max(len(r[2]) for r in rows + [("", "", headers[1], "", "", "", "")]),
        max(len(r[3]) for r in rows + [("", "", "", headers[2], "", "", "")]),
        max(len(r[4]) for r in rows + [("", "", "", "", headers[3], "", "")]),
        max(len(r[5]) for r in rows + [("", "", "", "", "", headers[4], "")]),
        max(len(r[6]) for r in rows + [("", "", "", "", "", "", headers[5])]),
    ]
    print(f"  {headers[0].ljust(widths[0])}  {headers[1].ljust(widths[1])}  {headers[2].ljust(widths[2])}  {headers[3].ljust(widths[3])}  {headers[4].ljust(widths[4])}  {headers[5].ljust(widths[5])}")
    print("-" * (sum(widths) + 13))
    for marker, alias, email, plan, h5, weekly, last in rows:
        print(f"{marker} {alias.ljust(widths[0])}  {email.ljust(widths[1])}  {plan.ljust(widths[2])}  {h5.ljust(widths[3])}  {weekly.ljust(widths[4])}  {last.ljust(widths[5])}")
    if current and current != reg.get("active_alias"):
        reg["active_alias"] = current
        save_registry(reg)
    return 0


def cmd_current(args: argparse.Namespace) -> int:
    reg = load_registry()
    current = detect_current_alias(reg, DEFAULT_CODEX_HOME)
    if current:
        print(current)
        return 0
    if reg.get("active_alias"):
        print(f"{reg['active_alias']} (registry，只能说明上次由 codex-ac 切换)")
        return 0
    print("<unknown>")
    return 1


def helpers_dir() -> Path:
    p = DEFAULT_AC_HOME / "helpers"
    p.mkdir(parents=True, exist_ok=True)
    try:
        p.chmod(0o700)
    except OSError:
        pass
    return p


def secrets_dir() -> Path:
    p = DEFAULT_AC_HOME / "secrets"
    p.mkdir(parents=True, exist_ok=True)
    try:
        p.chmod(0o700)
    except OSError:
        pass
    return p


def sanitize_provider_id(value: str) -> str:
    out = re.sub(r"[^A-Za-z0-9_-]+", "-", value.strip()).strip("-")
    if not out:
        out = "api"
    if not re.match(r"^[A-Za-z]", out):
        out = "api-" + out
    return out[:64]


def current_model_provider() -> Optional[str]:
    cfg = DEFAULT_CODEX_HOME / "config.toml"
    if not cfg.exists():
        return None
    in_table = False
    for line in cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
        if re.match(r"\s*\[", line):
            in_table = True
        if in_table:
            continue
        m = re.match(r"\s*model_provider\s*=\s*[\"']([^\"']+)[\"']", line)
        if m:
            return m.group(1)
    return None


def current_openai_base_url() -> Optional[str]:
    cfg = DEFAULT_CODEX_HOME / "config.toml"
    if not cfg.exists():
        return None
    in_table = False
    for line in cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
        if re.match(r"\s*\[", line):
            in_table = True
        if in_table:
            continue
        m = re.match(r"\s*openai_base_url\s*=\s*[\"']([^\"']+)[\"']", line)
        if m:
            return m.group(1)
    return None


def current_auth_mode(codex_home: Path = DEFAULT_CODEX_HOME) -> Optional[str]:
    p = codex_home / "auth.json"
    if not p.exists():
        return None
    try:
        obj = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None
    mode = obj.get("auth_mode")
    return mode if isinstance(mode, str) else None


def normalize_base_url(value: Optional[str]) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    return value.rstrip("/")


def account_provider_ids(rec: Dict[str, Any]) -> set[str]:
    providers: set[str] = set()
    provider = rec.get("provider_id")
    if isinstance(provider, str) and provider:
        providers.add(provider)
    legacy = rec.get("legacy_provider_ids")
    if isinstance(legacy, list):
        providers.update(v for v in legacy if isinstance(v, str) and v)
    elif isinstance(legacy, str) and legacy:
        providers.add(legacy)
    return providers


def detect_api_current_alias(reg: Dict[str, Any]) -> Optional[str]:
    provider = current_model_provider()
    if provider:
        for alias, rec in reg.get("accounts", {}).items():
            if rec.get("kind") == "api" and provider in account_provider_ids(rec):
                return alias
    if current_auth_mode() == "apikey":
        base = normalize_base_url(current_openai_base_url())
        for alias, rec in reg.get("accounts", {}).items():
            if rec.get("kind") == "api" and normalize_base_url(rec.get("base_url")) == base:
                return alias
    return None


def backup_current_auth(reason: str) -> Optional[Path]:
    src = DEFAULT_CODEX_HOME / "auth.json"
    if not src.exists():
        return None
    # API-key auth can be rebuilt from Keychain/fallback. Do not write another
    # copy of the key into codex-ac backups when switching back to ChatGPT.
    if current_auth_mode() == "apikey":
        return None
    ensure_dirs()
    dst = DEFAULT_AC_HOME / "backups" / f"auth.json.bak.{now_stamp()}.{reason}"
    copy_private(src, dst)
    return dst


def backup_config(reason: str) -> Optional[Path]:
    cfg = DEFAULT_CODEX_HOME / "config.toml"
    if not cfg.exists():
        return None
    ensure_dirs()
    dst = DEFAULT_AC_HOME / "backups" / f"config.toml.bak.{now_stamp()}.{reason}"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(cfg, dst)
    try:
        dst.chmod(0o600)
    except OSError:
        pass
    return dst


def remove_top_key(lines: list[str], key: str, only_value: Optional[str] = None) -> list[str]:
    out: list[str] = []
    in_table = False
    pat = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for line in lines:
        if re.match(r"^\s*\[", line):
            in_table = True
        if not in_table and pat.match(line):
            if only_value is None or only_value in line:
                continue
        out.append(line)
    return out


def set_top_key(lines: list[str], key: str, value: str) -> list[str]:
    assignment = f'{key} = {json.dumps(value, ensure_ascii=False)}'
    out: list[str] = []
    inserted = False
    replaced = False
    pat = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for line in lines:
        if not inserted and re.match(r"^\s*\[", line):
            if not replaced:
                out.append(assignment)
            inserted = True
        if not inserted and pat.match(line):
            out.append(assignment)
            replaced = True
            inserted = True
            continue
        out.append(line)
    if not inserted and not replaced:
        out.append(assignment)
    return out


def remove_provider_table(lines: list[str], provider: str) -> list[str]:
    out: list[str] = []
    skipping = False
    target = f"model_providers.{provider}"
    for line in lines:
        m = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
        if m:
            table = m.group(1).strip()
            if table == target or table.startswith(target + "."):
                skipping = True
                continue
            skipping = False
        if not skipping:
            out.append(line)
    return out


def api_provider_ids(reg: Dict[str, Any]) -> set[str]:
    providers: set[str] = set()
    for rec in reg.get("accounts", {}).values():
        if rec.get("kind") == "api":
            providers.update(account_provider_ids(rec))
    return providers


def clear_managed_api_config(lines: list[str], reg: Dict[str, Any]) -> list[str]:
    providers = api_provider_ids(reg)
    current = current_model_provider()
    if current in providers:
        lines = remove_top_key(lines, "model_provider", current)
    for provider in providers:
        lines = remove_provider_table(lines, provider)
    for rec in reg.get("accounts", {}).values():
        if rec.get("kind") == "api":
            base_url = rec.get("base_url")
            if isinstance(base_url, str) and base_url:
                lines = remove_top_key(lines, "openai_base_url", base_url)
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def write_api_key_helper(alias: str, service: str, account: str, fallback_file: Path) -> Path:
    helper = helpers_dir() / f"{alias}-key.sh"
    content = f'''#!/bin/sh
set -eu
PATH="/usr/bin:/bin:/usr/sbin:/sbin:${{PATH:-}}"
SERVICE={shlex.quote(service)}
ACCOUNT={shlex.quote(account)}
FALLBACK={shlex.quote(str(fallback_file))}
key="$(/usr/bin/security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null || true)"
if [ -n "$key" ]; then
  printf '%s\n' "$key"
  exit 0
fi
if [ -r "$FALLBACK" ]; then
  /bin/cat "$FALLBACK"
  exit 0
fi
exit 1
'''
    helper.write_text(content)
    helper.chmod(0o700)
    return helper


def store_api_key(alias: str, base_url: str, key: str) -> tuple[str, str, Path]:
    service = f"codex-ac:{alias}"
    account = re.sub(r"^https?://", "", base_url).split("/", 1)[0] or alias
    fallback = secrets_dir() / f"{alias}_api_key"
    saved = False
    if sys.platform == "darwin" and shutil.which("security"):
        proc = subprocess.run([
            "/usr/bin/security", "add-generic-password", "-a", account, "-s", service, "-U", "-w", key
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        saved = proc.returncode == 0
    if not saved:
        fallback.write_text(key.rstrip("\n") + "\n")
        fallback.chmod(0o600)
    return service, account, fallback


def read_key_from_user() -> str:
    if sys.stdin.isatty():
        key = getpass.getpass("Paste API key: ")
    else:
        key = sys.stdin.readline().strip()
    if not key:
        raise SystemExit("API key 为空，已取消。")
    return key


def normalize_usage_url(raw: Optional[str]) -> Optional[str]:
    if raw is None:
        return None
    value = raw.strip()
    if not value:
        return None
    if not re.match(r"^https?://", value, re.I):
        raise SystemExit("--usage-url 必须是 http(s) 完整地址")
    return value.rstrip("/")


def read_api_key_for_account(alias: str, rec: Dict[str, Any]) -> str:
    helper = rec.get("key_helper")
    if helper and Path(helper).exists():
        proc = subprocess.run([str(helper)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
        key = proc.stdout.strip()
        if proc.returncode == 0 and key:
            return key
    fallback = Path(rec.get("key_fallback") or secrets_dir() / f"{alias}_api_key")
    if fallback.exists():
        key = fallback.read_text(encoding="utf-8").strip()
        if key:
            return key
    raise SystemExit(f"API 账号 {alias} 的 key 不可读取，请重新执行 add-api 或检查 helper。")



def api_provider_block(provider: str, rec: Dict[str, Any]) -> list[str]:
    base_url = rec.get("base_url")
    if not isinstance(base_url, str) or not base_url:
        raise SystemExit(f"API 账号 {rec.get('alias') or provider} 缺少 base_url")
    helper = rec.get("key_helper")
    if not isinstance(helper, str) or not helper:
        raise SystemExit(f"API 账号 {rec.get('alias') or provider} 缺少 key helper，请重新执行 add-api。")
    name = rec.get("name") if isinstance(rec.get("name"), str) and rec.get("name") else provider
    wire_api = rec.get("wire_api") if rec.get("wire_api") in {"responses", "chat"} else "responses"
    return [
        "",
        f"[model_providers.{provider}]",
        f"name = {json.dumps(name, ensure_ascii=False)}",
        f"base_url = {json.dumps(base_url, ensure_ascii=False)}",
        f"wire_api = {json.dumps(wire_api, ensure_ascii=False)}",
        "",
        f"[model_providers.{provider}.auth]",
        f"command = {json.dumps(helper, ensure_ascii=False)}",
        "timeout_ms = 5000",
        "refresh_interval_ms = 300000",
    ]


def apply_api_profile(alias: str, rec: Dict[str, Any], reg: Dict[str, Any], no_backup: bool = False) -> Optional[Path]:
    base_url = rec.get("base_url")
    if not base_url:
        raise SystemExit(f"API 账号 {alias} 缺少 base_url")
    provider = rec.get("provider_id") if isinstance(rec.get("provider_id"), str) and rec.get("provider_id") else sanitize_provider_id(alias)
    cfg = DEFAULT_CODEX_HOME / "config.toml"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    lines = cfg.read_text(encoding="utf-8").splitlines() if cfg.exists() else []
    bak = None if no_backup else backup_config("switch-api")
    if not no_backup:
        backup_current_auth("switch-api")
    # Remove only provider blocks and top-level keys managed by codex-ac, then
    # activate this API profile through Codex's model_provider mechanism. The
    # API key stays in Keychain/private fallback and is read by the auth helper;
    # it is never written to config.toml.
    lines = clear_managed_api_config(lines, reg)
    lines = remove_top_key(lines, "model_provider")
    lines = set_top_key(lines, "model_provider", provider)
    if rec.get("model"):
        lines = set_top_key(lines, "model", rec["model"])
    while lines and lines[-1] == "":
        lines.pop()
    lines.extend(api_provider_block(provider, rec))
    tmp = cfg.with_suffix(".toml.tmp")
    tmp.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    os.replace(tmp, cfg)
    try:
        cfg.chmod(0o600)
    except OSError:
        pass
    return bak


def clear_api_config_for_chatgpt(reg: Dict[str, Any], no_backup: bool = False) -> Optional[Path]:
    cfg = DEFAULT_CODEX_HOME / "config.toml"
    if not cfg.exists():
        return None
    lines = cfg.read_text(encoding="utf-8").splitlines()
    new_lines = clear_managed_api_config(lines, reg)
    if new_lines == lines:
        return None
    bak = None if no_backup else backup_config("switch-chatgpt")
    tmp = cfg.with_suffix(".toml.tmp")
    tmp.write_text("\n".join(new_lines).rstrip() + "\n", encoding="utf-8")
    os.replace(tmp, cfg)
    try:
        cfg.chmod(0o600)
    except OSError:
        pass
    return bak


def cmd_add_api(args: argparse.Namespace) -> int:
    alias = validate_alias(args.alias)
    provider = sanitize_provider_id(args.provider or alias)
    usage_url = normalize_usage_url(args.usage_url)
    reg = load_registry()
    if alias in reg.get("accounts", {}) and not args.force:
        raise SystemExit(f"别名已存在：{alias}。如需覆盖，加 --force。")
    if args.reuse_key:
        service = args.key_service or f"codex-ac:{alias}"
        account = args.key_account or re.sub(r"^https?://", "", args.base_url).split("/", 1)[0] or alias
        fallback = secrets_dir() / f"{alias}_api_key"
    else:
        key = read_key_from_user()
        service, account, fallback = store_api_key(alias, args.base_url, key)
    helper = write_api_key_helper(alias, service, account, fallback)
    old = reg.get("accounts", {}).get(alias, {})
    rec = {
        "alias": alias,
        "kind": "api",
        "provider_id": provider,
        "base_url": args.base_url,
        "wire_api": args.wire_api,
        "model": args.model,
        "name": args.name or alias,
        "usage_url": usage_url,
        "plan": "API",
        "source": "api-relay",
        "key_service": service,
        "key_account": account,
        "key_fallback": str(fallback),
        "key_helper": str(helper),
        "created_at": old.get("created_at") or now_iso(),
        "updated_at": now_iso(),
        "last_switched_at": old.get("last_switched_at"),
    }
    reg.setdefault("accounts", {})[alias] = rec
    save_registry(reg)
    print(f"已添加 API/中转账号：{alias}")
    print(f"provider={provider}")
    print(f"base_url={args.base_url}")
    if usage_url:
        print(f"usage_url={usage_url}")
    if args.reuse_key:
        print("API key 将复用已存在的 Keychain/fallback helper，未写入 config.toml。")
    else:
        print("API key 已保存到 Keychain/本地私有 fallback，未写入 config.toml。")
    return 0

AUTH_EXPIRED_STATUSES = {"401", "403"}


def refresh_usage_for_alias_in_registry(reg: Dict[str, Any], alias: str, *, timeout: int = 12) -> tuple[bool, str]:
    auth_path = account_auth_file(alias, reg)
    snap, status = fetch_usage_snapshot(auth_path, timeout=timeout)
    rec = reg.get("accounts", {}).get(alias, {})
    if snap:
        rec["last_usage"] = snap
        rec["last_usage_at"] = int(time.time())
        rec.pop("last_usage_error", None)
        if snap.get("plan_type"):
            rec["plan"] = snap.get("plan_type")
        save_registry(reg)
        return True, status
    if status in AUTH_EXPIRED_STATUSES:
        rec["last_usage_error"] = "登录过期"
        save_registry(reg)
    return False, status


def auth_info_matches_account(info: Dict[str, Any], rec: Dict[str, Any]) -> bool:
    if info.get("identity_hash") and rec.get("identity_hash") and info.get("identity_hash") == rec.get("identity_hash"):
        return True
    if (
        info.get("chatgpt_user_id")
        and info.get("chatgpt_account_id")
        and info.get("chatgpt_user_id") == rec.get("chatgpt_user_id")
        and info.get("chatgpt_account_id") == rec.get("chatgpt_account_id")
    ):
        return True
    return False


def try_sync_current_auth_for_alias(alias: str, reg: Dict[str, Any], *, timeout: int = 12) -> tuple[bool, str]:
    """If the live ~/.codex/auth.json is a fresh login for alias, import it into the saved alias snapshot."""
    rec = reg.get("accounts", {}).get(alias, {})
    current_auth = DEFAULT_CODEX_HOME / "auth.json"
    if not rec or not current_auth.exists():
        return False, "current-auth-missing"
    try:
        info = auth_info(current_auth)
    except SystemExit as exc:
        return False, str(exc)
    if not auth_info_matches_account(info, rec):
        return False, "current-auth-different-account"
    snap, status = fetch_usage_snapshot(current_auth, timeout=timeout)
    if not snap:
        return False, status
    status_text = import_auth(alias, current_auth, "codex-ac-current-auth-sync", force=True)
    reg = load_registry()
    dst = reg.get("accounts", {}).get(alias, {})
    dst["last_usage"] = snap
    dst["last_usage_at"] = int(time.time())
    dst.pop("last_usage_error", None)
    if snap.get("plan_type"):
        dst["plan"] = snap.get("plan_type")
    save_registry(reg)
    return True, status_text


def ensure_chatgpt_auth_fresh_for_switch(alias: str, reg: Dict[str, Any], args: argparse.Namespace) -> Dict[str, Any]:
    if getattr(args, "force_login", False):
        print(f"账号 {alias} 按要求重新登录。")
        status = login_and_import_alias(alias, device_auth=getattr(args, "device_auth", False), keep_tmp=getattr(args, "keep_tmp", False), force=True)
        print(f"{status}: {alias}")
        return load_registry()
    if getattr(args, "no_auto_login", False) or getattr(args, "skip_expiry_check", False):
        return reg
    ok, status = refresh_usage_for_alias_in_registry(reg, alias)
    if ok:
        return reg
    if status in AUTH_EXPIRED_STATUSES:
        synced, sync_status = try_sync_current_auth_for_alias(alias, reg)
        if synced:
            print(f"检测到当前 ~/.codex/auth.json 已是 {alias} 的有效登录，已同步到 ca 快照。")
            return load_registry()
        print(f"账号 {alias} 登录已过期，需要重新登录。")
        status_text = login_and_import_alias(alias, device_auth=getattr(args, "device_auth", False), keep_tmp=getattr(args, "keep_tmp", False), force=True)
        print(f"{status_text}: {alias}")
        reg = load_registry()
        refresh_usage_for_alias_in_registry(reg, alias)
        return load_registry()
    print(f"账号 {alias} 用量刷新失败：{status}；继续切换，但 ca ll 可能仍显示旧快照。")
    return reg


def cmd_switch(args: argparse.Namespace) -> int:
    alias = validate_alias(args.alias)
    reg = load_registry()
    rec = reg.get("accounts", {}).get(alias)
    if not rec:
        raise SystemExit(f"账号别名不存在：{alias}")

    if rec.get("kind") == "api":
        bak = apply_api_profile(alias, rec, reg, no_backup=args.no_backup)
        reg["active_alias"] = alias
        reg["last_switch"] = {"alias": alias, "kind": "api", "at": now_iso(), "backup": str(bak) if bak else None}
        reg["accounts"][alias]["last_switched_at"] = now_iso()
        save_registry(reg)
        print(f"已切换到 API/中转账号：{alias}")
        if bak:
            print(f"已备份 config：{bak}")
        print("Start a new Codex session for the change to take effect.")
        if args.restart_app:
            restart_codex_app()
        return 0

    reg = ensure_chatgpt_auth_fresh_for_switch(alias, reg, args)
    rec = reg.get("accounts", {}).get(alias)
    if not rec or rec.get("kind") == "api":
        raise SystemExit(f"账号 {alias} 重新登录后记录异常，请检查 registry。")

    src = account_auth_file(alias, reg)
    dest = DEFAULT_CODEX_HOME / "auth.json"
    DEFAULT_CODEX_HOME.mkdir(parents=True, exist_ok=True)

    config_bak = clear_api_config_for_chatgpt(reg, no_backup=args.no_backup)
    before_sha = sha256_file(dest) if dest.exists() else None
    target_sha = sha256_file(src)
    if before_sha == target_sha:
        reg["active_alias"] = alias
        reg["accounts"][alias]["last_switched_at"] = now_iso()
        reg["last_switch"] = {"alias": alias, "kind": "chatgpt", "at": now_iso(), "backup": str(config_bak) if config_bak else None}
        save_registry(reg)
        print(f"已经是账号：{alias}")
        if config_bak:
            print(f"已清理 API provider 配置，备份 config：{config_bak}")
        refresh_remote_control_after_switch()
        return 0

    bak = None if args.no_backup else backup_current_auth("switch")
    old_mode = None
    if dest.exists():
        try:
            old_mode = stat.S_IMODE(dest.stat().st_mode)
        except OSError:
            old_mode = None
    copy_private(src, dest)
    if old_mode:
        try:
            dest.chmod(old_mode)
        except OSError:
            pass
    else:
        try:
            dest.chmod(0o600)
        except OSError:
            pass

    reg["active_alias"] = alias
    reg["last_switch"] = {"alias": alias, "kind": "chatgpt", "at": now_iso(), "backup": str(bak) if bak else None, "config_backup": str(config_bak) if config_bak else None}
    reg["accounts"][alias]["last_switched_at"] = now_iso()
    save_registry(reg)
    print(f"已切换到：{alias}")
    if bak:
        print(f"已备份原 auth：{bak}")
    if config_bak:
        print(f"已清理 API provider 配置，备份 config：{config_bak}")
    refresh_remote_control_after_switch()
    if args.restart_app:
        restart_codex_app()
    return 0

def restart_codex_app() -> None:
    if sys.platform != "darwin":
        eprint("--restart-app 目前只在 macOS 上处理。")
        return
    print("正在重启 Codex App...")
    subprocess.run(["osascript", "-e", 'tell application "Codex" to quit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    subprocess.run(["open", "-a", "Codex"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def remote_control_configured() -> bool:
    cfg = DEFAULT_CODEX_HOME / "config.toml"
    if cfg.exists():
        in_features = False
        for line in cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
            stripped = line.strip()
            m = re.match(r"^\[([^\]]+)\]\s*$", stripped)
            if m:
                in_features = m.group(1).strip() == "features"
                continue
            if in_features and re.match(r"^remote_control\s*=\s*true\b", stripped, re.I):
                return True

    settings = DEFAULT_CODEX_HOME / "app-server-daemon" / "settings.json"
    if settings.exists():
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
            if data.get("remoteControlEnabled") is True:
                return True
        except Exception:
            pass
    return False


def codex_for_daemon() -> Optional[str]:
    candidates = [
        DEFAULT_CODEX_HOME / "packages" / "standalone" / "current" / "codex",
        Path("/Applications/Codex.app/Contents/Resources/codex"),
    ]
    found = shutil.which("codex")
    if found:
        candidates.append(Path(found))
    for candidate in candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def refresh_remote_control_after_switch() -> None:
    # 2026-05-24: 用户远程控制改走 SSH 公网跳板。
    # ca 切换 ChatGPT 账号时不再刷新 Codex App 手机端 remote-control，
    # 避免过期 refresh token 导致切号后出现误导性报错。
    return


def cmd_import(args: argparse.Namespace) -> int:
    status = import_auth(args.alias, Path(args.path), "manual", force=args.force)
    print(f"{status}: {args.alias}")
    return 0


def cmd_import_current(args: argparse.Namespace) -> int:
    path = DEFAULT_CODEX_HOME / "auth.json"
    status = import_auth(args.alias, path, "current-auth", force=args.force)
    print(f"{status}: {args.alias}")
    return 0


def load_codex_auth_registry() -> Dict[str, Any]:
    p = DEFAULT_CODEX_HOME / "accounts" / "registry.json"
    if not p.exists():
        raise SystemExit(f"未找到 codex-auth registry：{p}")
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)


def codex_auth_snapshot_path(record: Dict[str, Any]) -> Path:
    key = record.get("account_key")
    if not key:
        raise SystemExit("codex-auth 记录缺少 account_key")
    base = DEFAULT_CODEX_HOME / "accounts"
    raw = base / f"{key}.auth.json"
    if raw.exists():
        return raw
    encoded = base64.urlsafe_b64encode(key.encode("utf-8")).decode("ascii").rstrip("=")
    return base / f"{encoded}.auth.json"


def auth_access_token_expiry(path: Path) -> Optional[int]:
    try:
        obj, _ = read_auth(path)
    except (OSError, SystemExit):
        return None
    tokens = obj.get("tokens") if isinstance(obj.get("tokens"), dict) else {}
    payload = decode_jwt_payload(tokens.get("access_token")) or {}
    exp = payload.get("exp")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)):
        return None
    return int(exp)


def auth_last_refresh_epoch(path: Path) -> Optional[int]:
    try:
        obj, _ = read_auth(path)
    except (OSError, SystemExit):
        return None
    value = obj.get("last_refresh")
    if not isinstance(value, str):
        return None
    parsed = parse_iso_timestamp_ms(value)
    return parsed // 1000 if parsed is not None else None


def auth_freshness(path: Path) -> Tuple[int, int, int]:
    try:
        mtime = int(path.stat().st_mtime)
    except OSError:
        mtime = 0
    return (
        auth_access_token_expiry(path) or 0,
        auth_last_refresh_epoch(path) or 0,
        mtime,
    )


def update_account_auth_metadata(rec: Dict[str, Any], path: Path) -> None:
    info = auth_info(path)
    rec["auth_sha256"] = info.get("auth_sha256")
    for key in [
        "email",
        "email_masked",
        "name",
        "plan",
        "auth_mode",
        "chatgpt_user_id",
        "chatgpt_account_id",
        "identity_hash",
    ]:
        if info.get(key) is not None:
            rec[key] = info.get(key)
    rec["updated_at"] = now_iso()


def matching_codex_auth_snapshot_paths(rec: Dict[str, Any]) -> list[Path]:
    registry = DEFAULT_CODEX_HOME / "accounts" / "registry.json"
    if not registry.exists():
        return []
    try:
        source = json.loads(registry.read_text(encoding="utf-8"))
    except Exception:
        return []
    records = source.get("accounts") or source.get("records") or []
    if not isinstance(records, list):
        return []
    identity_hash = rec.get("identity_hash")
    paths: list[Path] = []
    for item in records:
        if not isinstance(item, dict):
            continue
        item_hash = codex_auth_record_identity_hash(item)
        if not identity_hash or item_hash != identity_hash:
            continue
        try:
            path = codex_auth_snapshot_path(item)
        except SystemExit:
            continue
        if not path.exists():
            continue
        try:
            if not auth_info_matches_account(auth_info(path), rec):
                continue
        except (OSError, SystemExit):
            continue
        paths.append(path)
    return paths


def freshest_account_auth_path(alias: str, reg: Dict[str, Any]) -> Path:
    rec = reg.get("accounts", {}).get(alias, {})
    saved = account_auth_file(alias, reg)
    candidates = [saved, *matching_codex_auth_snapshot_paths(rec)]
    current = DEFAULT_CODEX_HOME / "auth.json"
    if current.exists():
        candidates.append(current)
    valid: list[Path] = []
    seen: set[str] = set()
    for path in candidates:
        key = str(path.resolve())
        if key in seen:
            continue
        seen.add(key)
        try:
            if auth_info_matches_account(auth_info(path), rec):
                valid.append(path)
        except (OSError, SystemExit):
            continue
    return max(valid or [saved], key=auth_freshness)


def sync_auth_to_saved_and_native(alias: str, reg: Dict[str, Any], source: Path) -> Path:
    rec = reg.get("accounts", {}).get(alias, {})
    saved = account_auth_file(alias, reg)
    source_rank = auth_freshness(source)
    if source.resolve() != saved.resolve() and source_rank > auth_freshness(saved):
        copy_private(source, saved)
    update_account_auth_metadata(rec, saved)
    for native in matching_codex_auth_snapshot_paths(rec):
        if native.resolve() in {saved.resolve(), source.resolve()}:
            continue
        try:
            if source_rank >= auth_freshness(native):
                copy_private(source, native)
        except OSError:
            continue
    return saved


def should_renew_auth(path: Path, now_epoch: int, threshold_seconds: int) -> bool:
    expires_at = auth_access_token_expiry(path)
    if expires_at is not None:
        return expires_at <= now_epoch + threshold_seconds
    refreshed_at = auth_last_refresh_epoch(path)
    if refreshed_at is None:
        return True
    fallback_age = max(24 * 60 * 60, 10 * 24 * 60 * 60 - threshold_seconds)
    return refreshed_at <= now_epoch - fallback_age


def classify_keepalive_refresh_failure(stderr: str) -> KeepaliveRefreshError:
    text = stderr.lower()
    if "refresh_token_expired" in text or "refresh token has expired" in text:
        return KeepaliveRefreshError("refresh_token_expired", permanent=True)
    if "refresh_token_reused" in text or "refresh token was already used" in text:
        return KeepaliveRefreshError("refresh_token_reused", permanent=True)
    if "refresh_token_invalidated" in text or "refresh token was revoked" in text:
        return KeepaliveRefreshError("refresh_token_invalidated", permanent=True)
    if "account mismatch" in text or "signed in to another account" in text:
        return KeepaliveRefreshError("account_mismatch", permanent=True)
    if "timed out" in text or "timeout" in text:
        return KeepaliveRefreshError("refresh_timeout")
    return KeepaliveRefreshError("refresh_failed")


def prepare_auth_for_isolated_app_server(path: Path, now_epoch: int) -> None:
    obj, _ = read_auth(path)
    tokens = obj.get("tokens") if isinstance(obj.get("tokens"), dict) else {}
    access_token = tokens.get("access_token")
    expires_at = auth_access_token_expiry(path)
    changed = False
    # app-server can start several proactive refresh tasks for an already expired
    # token. In the isolated copy only, move the JWT expiry outside that startup
    # window; account/read then performs one explicit authoritative refresh.
    if isinstance(access_token, str) and expires_at is not None and expires_at <= now_epoch + 5 * 60:
        parts = access_token.split(".")
        payload = decode_jwt_payload(access_token)
        if len(parts) >= 3 and payload is not None:
            payload["exp"] = now_epoch + 60 * 60
            encoded = base64.urlsafe_b64encode(
                json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii").rstrip("=")
            tokens["access_token"] = ".".join([parts[0], encoded, *parts[2:]])
            changed = True
    elif expires_at is None:
        obj["last_refresh"] = _dt.datetime.fromtimestamp(now_epoch, tz=_dt.timezone.utc).isoformat()
        changed = True
    if changed:
        write_private((json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8"), path)


def read_jsonrpc_response(
    proc: subprocess.Popen[bytes],
    request_id: int,
    timeout: int,
    read_buffer: bytearray,
) -> Dict[str, Any]:
    assert proc.stdout is not None
    deadline = time.monotonic() + timeout
    while True:
        newline = read_buffer.find(b"\n")
        if newline >= 0:
            raw = bytes(read_buffer[:newline])
            del read_buffer[: newline + 1]
            try:
                message = json.loads(raw)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if message.get("id") == request_id:
                return message
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise KeepaliveRefreshError("app_server_timeout")
        ready, _, _ = select.select([proc.stdout.fileno()], [], [], remaining)
        if not ready:
            raise KeepaliveRefreshError("app_server_timeout")
        chunk = os.read(proc.stdout.fileno(), 8192)
        if not chunk:
            raise KeepaliveRefreshError("app_server_closed")
        read_buffer.extend(chunk)


def refresh_auth_with_codex_app_server(
    alias: str,
    source: Path,
    rec: Dict[str, Any],
    *,
    now_epoch: int,
    timeout: int = KEEPALIVE_REFRESH_TIMEOUT_SECONDS,
) -> bytes:
    codex_bin = os.environ.get("CODEX_BIN") or shutil.which("codex")
    if not codex_bin:
        raise KeepaliveRefreshError("codex_not_found")
    before_obj, _ = read_auth(source)
    before_tokens = before_obj.get("tokens") if isinstance(before_obj.get("tokens"), dict) else {}
    if not isinstance(before_tokens.get("refresh_token"), str) or not before_tokens.get("refresh_token"):
        raise KeepaliveRefreshError("refresh_token_missing", permanent=True)
    ensure_dirs()
    with tempfile.TemporaryDirectory(prefix=f"keepalive-{alias}.", dir=str(DEFAULT_AC_HOME / "tmp")) as tmp:
        temp_home = Path(tmp)
        temp_auth = temp_home / "auth.json"
        copy_private(source, temp_auth)
        prepare_auth_for_isolated_app_server(temp_auth, now_epoch)
        staged_obj, staged_data = read_auth(temp_auth)
        staged_tokens = staged_obj.get("tokens") if isinstance(staged_obj.get("tokens"), dict) else {}
        staged_access = staged_tokens.get("access_token")
        staged_last_refresh = staged_obj.get("last_refresh")
        (temp_home / "config.toml").write_text(
            'cli_auth_credentials_store = "file"\n'
            'chatgpt_base_url = "http://127.0.0.1:9/backend-api"\n',
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CODEX_HOME"] = str(temp_home)
        no_proxy = env.get("NO_PROXY") or env.get("no_proxy") or ""
        no_proxy_parts = [part.strip() for part in no_proxy.split(",") if part.strip()]
        for host in ["127.0.0.1", "localhost"]:
            if host not in no_proxy_parts:
                no_proxy_parts.append(host)
        env["NO_PROXY"] = ",".join(no_proxy_parts)
        env["no_proxy"] = env["NO_PROXY"]
        for key in ["CODEX_ACCESS_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]:
            env.pop(key, None)
        proc = subprocess.Popen(
            [codex_bin, "app-server", "--stdio", "-c", 'cli_auth_credentials_store="file"'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=env,
        )
        stderr = ""
        read_buffer = bytearray()
        account_response: Optional[Dict[str, Any]] = None
        protocol_error: Optional[KeepaliveRefreshError] = None
        try:
            assert proc.stdin is not None
            initialize = {
                "method": "initialize",
                "id": 1,
                "params": {
                    "clientInfo": {
                        "name": "codex_auth_tools",
                        "title": "Codex Auth Tools",
                        "version": VERSION,
                    }
                },
            }
            proc.stdin.write((json.dumps(initialize, separators=(",", ":")) + "\n").encode())
            proc.stdin.flush()
            init_response = read_jsonrpc_response(proc, 1, min(timeout, 15), read_buffer)
            if init_response.get("error"):
                raise KeepaliveRefreshError("app_server_initialize_failed")
            proc.stdin.write((json.dumps({"method": "initialized", "params": {}}, separators=(",", ":")) + "\n").encode())
            proc.stdin.write(
                (
                    json.dumps(
                        {"method": "account/read", "id": 2, "params": {"refreshToken": True}},
                        separators=(",", ":"),
                    )
                    + "\n"
                ).encode()
            )
            proc.stdin.flush()
            account_response = read_jsonrpc_response(proc, 2, timeout, read_buffer)
        except KeepaliveRefreshError as exc:
            protocol_error = exc
        finally:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)
            if proc.stderr:
                stderr = proc.stderr.read().decode("utf-8", errors="replace")
        if account_response and account_response.get("error"):
            detail = json.dumps(account_response.get("error"), ensure_ascii=False) + "\n" + stderr
            raise classify_keepalive_refresh_failure(detail)
        if protocol_error is not None:
            classified = classify_keepalive_refresh_failure(stderr)
            if classified.code != "refresh_failed":
                raise classified
            raise protocol_error
        after_obj, after_data = read_auth(temp_auth)
        after_tokens = after_obj.get("tokens") if isinstance(after_obj.get("tokens"), dict) else {}
        after_access = after_tokens.get("access_token")
        if after_obj.get("last_refresh") == staged_last_refresh or after_access == staged_access:
            raise classify_keepalive_refresh_failure(stderr)
        try:
            refreshed_info = auth_info(temp_auth)
        except SystemExit as exc:
            raise KeepaliveRefreshError("refreshed_auth_invalid") from exc
        if not auth_info_matches_account(refreshed_info, rec):
            raise KeepaliveRefreshError("refreshed_account_mismatch", permanent=True)
        expires_at = auth_access_token_expiry(temp_auth)
        if expires_at is None or expires_at <= now_epoch:
            raise KeepaliveRefreshError("refreshed_access_token_invalid")
        if not after_data or after_data == staged_data:
            raise KeepaliveRefreshError("refresh_not_applied")
        return after_data


def keepalive_status_text(status: str) -> str:
    return {
        "active": "当前账号由 Codex 维护",
        "fresh": "凭证仍有效",
        "due": "需要续期",
        "renewed": "续期成功",
        "api": "API 账号无需续期",
        "needs_login": "登录已失效，需要重新登录",
        "error": "续期失败，稍后重试",
    }.get(status, status)


def cmd_keepalive(args: argparse.Namespace) -> int:
    reg = load_registry()
    accounts = reg.get("accounts", {})
    selected = [validate_alias(v) for v in args.aliases] if args.aliases else list(accounts.keys())
    missing = [alias for alias in selected if alias not in accounts]
    if missing:
        raise SystemExit("账号别名不存在：" + ", ".join(missing))
    now_epoch = int(time.time())
    threshold_seconds = max(1, int(args.threshold_hours)) * 60 * 60
    active = detect_current_alias(reg, DEFAULT_CODEX_HOME) or reg.get("active_alias")
    counts = {"renewed": 0, "fresh": 0, "active": 0, "api": 0, "failed": 0, "due": 0}
    changed = False
    for alias in selected:
        rec = accounts[alias]
        if rec.get("kind") == "api":
            status = "api"
            counts[status] += 1
            if not args.dry_run:
                rec["last_keepalive_check_at"] = now_iso()
                rec["last_keepalive_status"] = status
                rec.pop("last_keepalive_error", None)
                changed = True
            if not args.quiet:
                print(f"{alias}: {keepalive_status_text(status)}")
            continue
        try:
            saved = account_auth_file(alias, reg)
            freshest = freshest_account_auth_path(alias, reg)
            if not args.dry_run:
                saved = sync_auth_to_saved_and_native(alias, reg, freshest)
            else:
                saved = freshest
        except (OSError, SystemExit):
            status = "error"
            error_code = "auth_snapshot_invalid"
            counts["failed"] += 1
            if not args.dry_run:
                rec["last_keepalive_check_at"] = now_iso()
                rec["last_keepalive_status"] = status
                rec["last_keepalive_error"] = error_code
                changed = True
            if not args.quiet:
                print(f"{alias}: {keepalive_status_text(status)} ({error_code})")
            continue
        if alias == active:
            status = "active"
            counts[status] += 1
            if not args.dry_run:
                rec["last_keepalive_check_at"] = now_iso()
                rec["last_keepalive_status"] = status
                rec.pop("last_keepalive_error", None)
                changed = True
            if not args.quiet:
                print(f"{alias}: {keepalive_status_text(status)}")
            continue
        due = bool(args.force) or should_renew_auth(saved, now_epoch, threshold_seconds)
        if not due:
            status = "fresh"
            counts[status] += 1
            if not args.dry_run:
                rec["last_keepalive_check_at"] = now_iso()
                rec["last_keepalive_status"] = status
                rec.pop("last_keepalive_error", None)
                changed = True
            if not args.quiet:
                expires_at = auth_access_token_expiry(saved)
                remaining_days = max(0, (expires_at - now_epoch + 86399) // 86400) if expires_at else None
                suffix = f"（约 {remaining_days} 天）" if remaining_days is not None else ""
                print(f"{alias}: {keepalive_status_text(status)}{suffix}")
            continue
        if args.dry_run:
            counts["due"] += 1
            if not args.quiet:
                print(f"{alias}: {keepalive_status_text('due')}")
            continue
        try:
            before_sha = sha256_file(saved)
            refreshed_data = refresh_auth_with_codex_app_server(
                alias,
                saved,
                rec,
                now_epoch=now_epoch,
                timeout=max(10, int(args.timeout)),
            )
            if sha256_file(saved) != before_sha:
                raise KeepaliveRefreshError("auth_changed_during_refresh")
            try:
                write_private(refreshed_data, saved)
            except OSError as exc:
                raise KeepaliveRefreshError("auth_write_failed") from exc
            update_account_auth_metadata(rec, saved)
            native_sync_failed = False
            for native in matching_codex_auth_snapshot_paths(rec):
                try:
                    write_private(refreshed_data, native)
                except OSError:
                    native_sync_failed = True
            status = "renewed"
            counts[status] += 1
            rec["last_keepalive_check_at"] = now_iso()
            rec["last_keepalive_at"] = now_iso()
            rec["last_keepalive_status"] = status
            if native_sync_failed:
                rec["last_keepalive_error"] = "native_sync_failed"
            else:
                rec.pop("last_keepalive_error", None)
            rec.pop("last_usage_error", None)
            changed = True
            if not args.quiet:
                print(f"{alias}: {keepalive_status_text(status)}")
        except (KeepaliveRefreshError, OSError, SystemExit) as exc:
            if isinstance(exc, KeepaliveRefreshError):
                error_code = exc.code
                permanent = exc.permanent
            else:
                error_code = "auth_io_failed"
                permanent = False
            status = "needs_login" if permanent else "error"
            counts["failed"] += 1
            rec["last_keepalive_check_at"] = now_iso()
            rec["last_keepalive_status"] = status
            rec["last_keepalive_error"] = error_code
            changed = True
            if not args.quiet:
                print(f"{alias}: {keepalive_status_text(status)} ({error_code})")
    if changed:
        save_registry(reg)
    if args.quiet:
        print(
            "keepalive: "
            f"renewed={counts['renewed']} fresh={counts['fresh']} active={counts['active']} "
            f"failed={counts['failed']}"
        )
    return 1 if counts["failed"] else 0


def unique_alias(base: str, existing: set[str]) -> str:
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", base.strip()) or "account"
    if not re.match(r"^[A-Za-z0-9]", base):
        base = "account-" + base
    base = base[:64]
    if base not in existing and base not in RESERVED and ALIAS_RE.match(base):
        return base
    for i in range(2, 1000):
        cand = (base[: max(1, 64 - len(str(i)) - 1)] + f"-{i}")
        if cand not in existing and cand not in RESERVED and ALIAS_RE.match(cand):
            return cand
    raise SystemExit("无法生成唯一别名")


def cmd_import_codex_auth(args: argparse.Namespace) -> int:
    src_reg = load_codex_auth_registry()
    records = src_reg.get("accounts") or src_reg.get("records") or []
    if not isinstance(records, list):
        raise SystemExit("codex-auth registry 格式不支持")
    reg = load_registry()
    existing = set(reg.get("accounts", {}).keys())
    count = 0
    for idx, rec in enumerate(records, 1):
        alias = rec.get("alias") or f"account{idx}"
        alias = unique_alias(alias, existing) if alias in existing and not args.force else validate_alias(alias)
        path = codex_auth_snapshot_path(rec)
        if not path.exists():
            eprint(f"跳过：{alias} 快照不存在：{path}")
            continue
        status = import_auth(alias, path, "codex-auth", force=args.force)
        # 迁移 codex-auth 已经刷到的 usage 快照，避免只迁移登录态。
        dst_reg = load_registry()
        dst = dst_reg.get("accounts", {}).get(alias)
        if dst is not None:
            for k in ["last_usage", "last_usage_at", "last_local_rollout", "last_used_at"]:
                if k in rec and rec.get(k) is not None:
                    dst[k] = rec.get(k)
            dst.pop("last_usage_error", None)
            save_registry(dst_reg)
        existing.add(alias)
        count += 1
        print(f"{status}: {alias}")
    # 迁移后按当前 ~/.codex/auth.json 矫正 active_alias，不替换 auth。
    reg = load_registry()
    cur = detect_current_alias(reg, DEFAULT_CODEX_HOME)
    if cur:
        reg["active_alias"] = cur
        save_registry(reg)
    print(f"完成，导入/更新 {count} 个账号。")
    return 0


def login_and_import_alias(alias: str, *, device_auth: bool = False, keep_tmp: bool = False, force: bool = True, source: str = "codex-ac-auto-login") -> str:
    alias = validate_alias(alias)
    ensure_dirs()
    before_sha = sha256_file(DEFAULT_CODEX_HOME / "auth.json") if (DEFAULT_CODEX_HOME / "auth.json").exists() else None
    tmp_parent = DEFAULT_AC_HOME / "tmp"
    tmp_parent.mkdir(parents=True, exist_ok=True)
    tmp_home = Path(tempfile.mkdtemp(prefix=f"{alias}.", dir=str(tmp_parent)))
    try:
        cmd = ["codex", "login"]
        if device_auth:
            cmd.append("--device-auth")
        print(f"临时 CODEX_HOME：{tmp_home}")
        print("请在弹出的网页登录账号；当前 ~/.codex/auth.json 不会被改动。")
        env = os.environ.copy()
        env["CODEX_HOME"] = str(tmp_home)
        ret = subprocess.run(cmd, env=env).returncode
        if ret != 0:
            raise SystemExit(f"codex login 失败，退出码：{ret}")
        auth_path = tmp_home / "auth.json"
        if not auth_path.exists() or auth_path.stat().st_size == 0:
            raise SystemExit(f"临时登录没有产生 auth.json：{auth_path}")
        after_sha = sha256_file(DEFAULT_CODEX_HOME / "auth.json") if (DEFAULT_CODEX_HOME / "auth.json").exists() else None
        if before_sha != after_sha:
            raise SystemExit("检测到 ~/.codex/auth.json 被意外改变，已停止导入。请手工检查。")
        return import_auth(alias, auth_path, source, force=force)
    finally:
        if keep_tmp:
            print(f"保留临时目录：{tmp_home}")
        else:
            shutil.rmtree(tmp_home, ignore_errors=True)


def cmd_add(args: argparse.Namespace) -> int:
    alias = validate_alias(args.alias)
    reg = load_registry()
    if alias in reg.get("accounts", {}) and not args.force:
        raise SystemExit(f"别名已存在：{alias}。如需覆盖，加 --force。")
    status = login_and_import_alias(alias, device_auth=args.device_auth, keep_tmp=args.keep_tmp, force=args.force, source="codex-ac-add")
    print(f"{status}: {alias}")
    return 0

def cmd_relogin(args: argparse.Namespace) -> int:
    alias = validate_alias(args.alias)
    reg = load_registry()
    rec = reg.get("accounts", {}).get(alias)
    if not rec:
        raise SystemExit(f"账号别名不存在：{alias}")
    if rec.get("kind") == "api":
        raise SystemExit("API/中转账号不需要网页登录；如需改 key，请重新执行 add-api。")
    status = login_and_import_alias(alias, device_auth=args.device_auth, keep_tmp=args.keep_tmp, force=True, source="codex-ac-relogin")
    print(f"{status}: {alias}")
    reg = load_registry()
    ok, usage_status = refresh_usage_for_alias_in_registry(reg, alias)
    if ok:
        print(f"已刷新用量：{alias}")
    else:
        print(f"用量刷新失败：{usage_status}")
    if args.switch:
        args2 = argparse.Namespace(alias=alias, restart_app=args.restart_app, no_backup=args.no_backup, device_auth=args.device_auth, force_login=False, no_auto_login=True, skip_expiry_check=True, keep_tmp=args.keep_tmp)
        return cmd_switch(args2)
    print("未切换当前账号；需要切换时执行：ca s " + alias)
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    alias = validate_alias(args.alias)
    reg = load_registry()
    if alias not in reg.get("accounts", {}):
        raise SystemExit(f"账号别名不存在：{alias}")
    if not args.yes:
        raise SystemExit("删除需要加 --yes，避免误删。")
    path = account_auth_file(alias, reg)
    reg["accounts"].pop(alias, None)
    if reg.get("active_alias") == alias:
        reg["active_alias"] = None
    save_registry(reg)
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    print(f"已删除账号记录：{alias}")
    return 0


def cmd_rename(args: argparse.Namespace) -> int:
    old = validate_alias(args.old_alias)
    new = validate_alias(args.new_alias)
    reg = load_registry()
    accounts = reg.get("accounts", {})
    if old not in accounts:
        raise SystemExit(f"账号别名不存在：{old}")
    if new in accounts and not args.force:
        raise SystemExit(f"目标别名已存在：{new}。如需覆盖，加 --force。")
    old_path = account_auth_file(old, reg) if accounts[old].get("kind") != "api" else None
    if new in accounts:
        existing = accounts[new]
        if existing.get("kind") != "api":
            try:
                account_auth_file(new, reg).unlink()
            except Exception:
                pass
    rec = accounts.pop(old)
    rec["alias"] = new
    if rec.get("kind") == "api":
        old_provider = rec.get("provider_id")
        new_provider = sanitize_provider_id(new)
        if old_provider == sanitize_provider_id(old):
            rec["provider_id"] = new_provider
            if old_provider and old_provider != new_provider:
                legacy = rec.get("legacy_provider_ids")
                legacy_list = [v for v in legacy if isinstance(v, str) and v] if isinstance(legacy, list) else []
                if old_provider not in legacy_list:
                    legacy_list.append(old_provider)
                rec["legacy_provider_ids"] = legacy_list
        if rec.get("name") == old or not rec.get("name"):
            rec["name"] = new
    else:
        assert old_path is not None
        new_path = alias_auth_path(new)
        copy_private(old_path, new_path)
        try:
            old_path.unlink()
        except Exception:
            pass
        rec["auth_file"] = str(new_path.relative_to(DEFAULT_AC_HOME))
    rec["updated_at"] = now_iso()
    accounts[new] = rec
    if reg.get("active_alias") == old:
        reg["active_alias"] = new
    save_registry(reg)
    print(f"Renamed: {old} -> {new}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    alias = validate_alias(args.alias)
    reg = load_registry()
    src = account_auth_file(alias, reg)
    home = DEFAULT_AC_HOME / "homes" / alias
    home.mkdir(parents=True, exist_ok=True)
    try:
        home.chmod(0o700)
    except OSError:
        pass
    copy_private(src, home / "auth.json")
    # 复用主配置，避免 CODEX_HOME 隔离后丢 config/prompts。只创建不存在的软链。
    for name in ["config.toml", "AGENTS.md"]:
        target = DEFAULT_CODEX_HOME / name
        link = home / name
        if target.exists() and not link.exists():
            try:
                link.symlink_to(target)
            except OSError:
                shutil.copy2(target, link)
    prompts = DEFAULT_CODEX_HOME / "prompts"
    prompts_link = home / "prompts"
    if prompts.exists() and not prompts_link.exists():
        try:
            prompts_link.symlink_to(prompts, target_is_directory=True)
        except OSError:
            pass
    cmd = ["codex"] + (args.codex_args or [])
    env = os.environ.copy()
    env["CODEX_HOME"] = str(home)
    print(f"使用账号 {alias} 启动：CODEX_HOME={home}")
    os.execvpe(cmd[0], cmd, env)
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    print(f"codex-ac {VERSION}")
    print(f"AC_HOME={DEFAULT_AC_HOME}")
    print(f"CODEX_HOME={DEFAULT_CODEX_HOME}")
    print(f"codex={shutil.which('codex') or '<not found>'}")
    print(f"registry={registry_path()} {'exists' if registry_path().exists() else 'missing'}")
    print(f"auth.json={(DEFAULT_CODEX_HOME/'auth.json')} {'exists' if (DEFAULT_CODEX_HOME/'auth.json').exists() else 'missing'}")
    reg = load_registry()
    print(f"accounts={len(reg.get('accounts', {}))}")
    print(f"current={detect_current_alias(reg, DEFAULT_CODEX_HOME) or '<unknown>'}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="codex-ac", description="本机 Codex 多账号管理器。")
    p.add_argument("--version", action="version", version=f"codex-ac {VERSION}")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("list", aliases=["ll", "ls", "la"], help="列出账号和用量快照")
    sp.add_argument("--api", action="store_true", help="通过 codex-auth 原生 API 路径刷新所有账号")
    sp.add_argument("--refresh", action="store_true", help="等同 --api，兼容旧用法")
    sp.add_argument("--skip-api", action="store_true", help="通过 codex-auth --skip-api 路径刷新 active 本地用量")
    sp.add_argument("--cached", action="store_true", help="只读 codex-ac 缓存，不触发任何刷新；最快")
    sp.set_defaults(func=cmd_list, account_lock=True)

    sp = sub.add_parser("refresh", help="刷新账号 5H/Weekly 用量；默认走 codex-auth API 路径")
    sp.add_argument("aliases", nargs="*")
    sp.add_argument("--skip-api", action="store_true", help="只走 codex-auth --skip-api 本地路径")
    sp.set_defaults(func=cmd_refresh, account_lock=True)

    sp = sub.add_parser("keepalive", help="检查已保存账号，并在登录凭证临近过期时自动续期")
    sp.add_argument("aliases", nargs="*", help="只检查指定账号；默认检查全部")
    sp.add_argument("--dry-run", action="store_true", help="只显示计划，不写文件、不发起续期")
    sp.add_argument("--force", action="store_true", help="强制续期所有非当前 ChatGPT 账号")
    sp.add_argument(
        "--threshold-hours",
        type=int,
        default=KEEPALIVE_THRESHOLD_SECONDS // (60 * 60),
        help="剩余多少小时内触发续期，默认 72",
    )
    sp.add_argument("--timeout", type=int, default=KEEPALIVE_REFRESH_TIMEOUT_SECONDS, help=argparse.SUPPRESS)
    sp.add_argument("--quiet", action="store_true", help="只输出汇总，供定时任务使用")
    sp.set_defaults(func=cmd_keepalive, account_lock=True, account_lock_nonblocking=True)

    sp = sub.add_parser("current", help="显示当前匹配账号别名")
    sp.set_defaults(func=cmd_current)

    sp = sub.add_parser("add", help="登录并添加新账号，不改变当前 ~/.codex/auth.json")
    sp.add_argument("alias")
    sp.add_argument("--device-auth", action="store_true", help="使用 codex login --device-auth")
    sp.add_argument("--force", action="store_true", help="覆盖同名账号")
    sp.add_argument("--keep-tmp", action="store_true", help="保留临时 CODEX_HOME，调试用")
    sp.set_defaults(func=cmd_add, account_lock=True)

    sp = sub.add_parser("add-api", help="添加 API key / 中转域名账号，不写 key 到 config.toml")
    sp.add_argument("alias")
    sp.add_argument("--base-url", required=True, help="OpenAI-compatible base URL，例如 https://codeapi.example.com/v1")
    sp.add_argument("--usage-url", help="可选：中转用量接口完整地址；默认由 base-url 拼出 /usage，例如 https://relay.example.com/v1/usage")
    sp.add_argument("--provider", help="Codex model_provider id；默认用 alias")
    sp.add_argument("--model", help="切换时同时设置 model；不传则保留当前 model")
    sp.add_argument("--wire-api", default="responses", choices=["responses", "chat"], help="Codex provider wire_api，默认 responses")
    sp.add_argument("--name", help="provider display name")
    sp.add_argument("--force", action="store_true", help="覆盖同名 profile")
    sp.add_argument("--reuse-key", action="store_true", help="不提示输入 key，复用已有 Keychain/fallback")
    sp.add_argument("--key-service", help="--reuse-key 时指定 Keychain service")
    sp.add_argument("--key-account", help="--reuse-key 时指定 Keychain account")
    sp.set_defaults(func=cmd_add_api, account_lock=True)

    sp = sub.add_parser("import", help="导入一个 auth.json，不切换当前账号")
    sp.add_argument("alias")
    sp.add_argument("path")
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_import, account_lock=True)

    sp = sub.add_parser("import-current", help="把当前 ~/.codex/auth.json 导入为指定别名")
    sp.add_argument("alias")
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_import_current, account_lock=True)

    sp = sub.add_parser("import-codex-auth", help="从现有 codex-auth 账号库迁移账号")
    sp.add_argument("--force", action="store_true", help="同名别名时覆盖；默认自动生成唯一别名")
    sp.set_defaults(func=cmd_import_codex_auth, account_lock=True)

    sp = sub.add_parser("switch", aliases=["s"], help="切换当前 ~/.codex/auth.json 到指定账号")
    sp.add_argument("alias")
    sp.add_argument("--restart-app", action="store_true", help="切换后重启 Codex App，macOS")
    sp.add_argument("--no-backup", action="store_true", help="不备份当前 auth.json")
    sp.add_argument("--device-auth", action="store_true", help="目标账号过期自动重登时使用设备码")
    sp.add_argument("--force-login", action="store_true", help="切换前强制重新登录目标账号")
    sp.add_argument("--no-auto-login", action="store_true", help="目标账号过期时不自动重新登录")
    sp.add_argument("--skip-expiry-check", action="store_true", help="跳过切换前过期检测")
    sp.add_argument("--keep-tmp", action="store_true", help="自动重登时保留临时 CODEX_HOME，调试用")
    sp.set_defaults(func=cmd_switch, account_lock=True)

    sp = sub.add_parser("rename", help="重命名账号别名")
    sp.add_argument("old_alias")
    sp.add_argument("new_alias")
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_rename, account_lock=True)

    sp = sub.add_parser("relogin", aliases=["r"], help="重新登录并更新指定 ChatGPT 账号快照；默认不切换当前账号")
    sp.add_argument("alias")
    sp.add_argument("--device-auth", action="store_true", help="使用设备码登录")
    sp.add_argument("--keep-tmp", action="store_true", help="保留临时 CODEX_HOME，调试用")
    sp.add_argument("--switch", action="store_true", help="重新登录后立即切换到该账号")
    sp.add_argument("--restart-app", action="store_true", help="配合 --switch，切换后重启 Codex App")
    sp.add_argument("--no-backup", action="store_true", help="配合 --switch，不备份当前 auth.json")
    sp.set_defaults(func=cmd_relogin, account_lock=True)

    sp = sub.add_parser("remove", help="删除账号快照，不改当前 auth.json")
    sp.add_argument("alias")
    sp.add_argument("--yes", action="store_true")
    sp.set_defaults(func=cmd_remove, account_lock=True)

    sp = sub.add_parser("run", help="用指定账号隔离启动 codex CLI，不改全局 auth.json")
    sp.add_argument("alias")
    sp.add_argument("codex_args", nargs=argparse.REMAINDER)
    sp.set_defaults(func=cmd_run)

    sp = sub.add_parser("doctor", help="检查环境")
    sp.set_defaults(func=cmd_doctor)
    return p


def main() -> int:
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "__list-ui":
            with account_store_lock():
                ui = Path(__file__).with_name("list.mjs")
                node = shutil.which("node")
                if not node:
                    raise SystemExit("未找到 node，无法显示账号列表。")
                return subprocess.run([node, str(ui), *sys.argv[2:]], check=False).returncode
        args = build_parser().parse_args()
        if getattr(args, "account_lock", False):
            try:
                with account_store_lock(nonblocking=bool(getattr(args, "account_lock_nonblocking", False))):
                    return int(args.func(args) or 0)
            except AccountStoreBusy:
                if getattr(args, "cmd", None) == "keepalive":
                    if not getattr(args, "quiet", False):
                        print("keepalive: 已有账号操作正在进行，本次跳过")
                    return 0
                raise SystemExit("账号库正被另一个 ca 操作使用，请稍后重试。")
        return int(args.func(args) or 0)
    except KeyboardInterrupt:
        eprint("已取消。")
        return 130
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
