#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const home = os.homedir();
const acHome = process.env.CODEX_AC_HOME || path.join(home, '.codex-ac');
const codexHome = process.env.CODEX_HOME || path.join(home, '.codex');
const usageProxy = process.env.CODEX_AC_USAGE_PROXY || process.env.HTTPS_PROXY || process.env.https_proxy || '';
const defaultWhamUsageUrl = 'https://chatgpt.com/backend-api/wham/usage';
const whamUsageUrl = process.env.NODE_ENV === 'test' && process.env.CODEX_AC_TEST_WHAM_USAGE_URL
  ? process.env.CODEX_AC_TEST_WHAM_USAGE_URL
  : defaultWhamUsageUrl;
const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  console.log(`usage: codex-ac list [--api] [--refresh] [--skip-api] [--cached] [--alias] [--mask] [--no-color]

列出账号、用量和可用重置券数量；默认 UI 对齐 codex-auth list。

options:
  --api       默认行为；通过 codex-auth 原生 API 路径刷新所有账号
  --refresh   等同 --api
  --skip-api  通过 codex-auth --skip-api 路径刷新 active 本地用量
  --cached    只读 codex-ac 缓存，不触发任何刷新；最快
  --alias     在最右侧额外显示 codex-ac 别名
  --mask      脱敏显示邮箱
  --no-color  禁用颜色
  -h, --help  显示帮助`);
  process.exit(0);
}
const cached = args.includes('--cached');
const skipApi = args.includes('--skip-api');
const showAlias = args.includes('--alias');
const maskAccount = args.includes('--mask');
const noColor = args.includes('--no-color');
const useColor = !noColor && process.stdout.isTTY;
// 默认必须和 `codex-auth list` 一致：走 API；只有显式 --skip-api 才走本地快照。
const api = !skipApi;

function readJson(p, fallback=null) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fallback; }
}
function writeJsonPrivate(p, obj) {
  const tmp = `${p}.tmp.${process.pid}`;
  fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, p);
  try { fs.chmodSync(p, 0o600); } catch {}
}
function sha256(s) { return crypto.createHash('sha256').update(s).digest('hex'); }
function b64urlDecodeJson(seg) {
  try {
    seg += '='.repeat((4 - seg.length % 4) % 4);
    return JSON.parse(Buffer.from(seg, 'base64url').toString('utf8'));
  } catch { return null; }
}
function authInfo(p) {
  const obj = readJson(p, {});
  const tok = obj?.tokens?.id_token;
  let payload = null;
  if (typeof tok === 'string' && tok.split('.').length >= 3) payload = b64urlDecodeJson(tok.split('.')[1]);
  const ns = payload?.['https://api.openai.com/auth'] || {};
  const email = obj.email || payload?.email || null;
  const user = ns.chatgpt_user_id || ns.user_id || payload?.sub || null;
  const account = ns.chatgpt_account_id || obj.chatgpt_account_id || null;
  const identity = user && account ? `${user}::${account}` : (user || (email ? email.toLowerCase() : null));
  return { email, user, account, identityHash: identity ? sha256(identity) : null };
}
function currentModelProvider() {
  const p = path.join(codexHome, 'config.toml');
  if (!fs.existsSync(p)) return null;
  let inTable = false;
  for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    if (/^\s*\[/.test(line)) inTable = true;
    if (inTable) continue;
    const m = line.match(/^\s*model_provider\s*=\s*["']([^"']+)["']/);
    if (m) return m[1];
  }
  return null;
}
function currentOpenaiBaseUrl() {
  const p = path.join(codexHome, 'config.toml');
  if (!fs.existsSync(p)) return null;
  let inTable = false;
  for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    if (/^\s*\[/.test(line)) inTable = true;
    if (inTable) continue;
    const m = line.match(/^\s*openai_base_url\s*=\s*["']([^"']+)["']/);
    if (m) return m[1].replace(/\/+$/, '');
  }
  return null;
}
function currentAuthMode() {
  const p = path.join(codexHome, 'auth.json');
  const obj = readJson(p, {});
  return typeof obj?.auth_mode === 'string' ? obj.auth_mode : null;
}
function currentAlias(reg) {
  const provider = currentModelProvider();
  if (provider) {
    for (const [alias, rec] of Object.entries(reg.accounts || {})) {
      const ids = new Set([rec.provider_id, ...(Array.isArray(rec.legacy_provider_ids) ? rec.legacy_provider_ids : [])].filter(Boolean));
      if (rec.kind === 'api' && ids.has(provider)) return alias;
    }
  }
  if (currentAuthMode() === 'apikey') {
    const base = currentOpenaiBaseUrl();
    for (const [alias, rec] of Object.entries(reg.accounts || {})) {
      const recBase = typeof rec.base_url === 'string' ? rec.base_url.replace(/\/+$/, '') : null;
      if (rec.kind === 'api' && recBase && recBase === base) return alias;
    }
  }
  const p = path.join(codexHome, 'auth.json');
  if (!fs.existsSync(p)) return null;
  const cur = authInfo(p);
  const accounts = reg.accounts || {};
  for (const [alias, rec] of Object.entries(accounts)) {
    if (cur.identityHash && rec.identity_hash === cur.identityHash) return alias;
  }
  return null;
}
function codexAuthIdentityHash(rec) {
  if (rec?.account_key) return sha256(rec.account_key);
  if (rec?.chatgpt_user_id && rec?.chatgpt_account_id) return sha256(`${rec.chatgpt_user_id}::${rec.chatgpt_account_id}`);
  return null;
}

function usageWindowFromApi(w) {
  if (!w || typeof w !== 'object') return null;
  const used = Number(w.used_percent);
  const seconds = Number(w.limit_window_seconds);
  const reset = Number(w.reset_at ?? w.resets_at);
  if (!Number.isFinite(used) || !Number.isFinite(seconds) || !Number.isFinite(reset)) return null;
  return {
    used_percent: Math.trunc(used),
    window_minutes: Math.trunc(seconds / 60),
    resets_at: Math.trunc(reset),
  };
}
function nonNegativeInt(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.trunc(value) : null;
}
function usageSnapshotFromWham(data) {
  const rl = data?.rate_limit;
  if (!rl || typeof rl !== 'object') return null;
  const primary = usageWindowFromApi(rl.primary_window);
  const secondary = usageWindowFromApi(rl.secondary_window);
  if (!primary && !secondary) return null;
  const credits = data?.credits && typeof data.credits === 'object' ? {
    has_credits: Boolean(data.credits.has_credits),
    unlimited: Boolean(data.credits.unlimited),
    balance: data.credits.balance ?? null,
  } : undefined;
  const resetCredits = nonNegativeInt(data?.rate_limit_reset_credits?.available_count);
  return {
    primary,
    secondary,
    credits,
    plan_type: typeof data?.plan_type === 'string' ? data.plan_type : undefined,
    reset_credits_available: resetCredits,
  };
}

function mergeUsageSnapshots(current, incoming) {
  if (!incoming || typeof incoming !== 'object') return current;
  const merged = { ...incoming };
  if (!Object.prototype.hasOwnProperty.call(incoming, 'reset_credits_available')
      && current && typeof current === 'object'
      && Object.prototype.hasOwnProperty.call(current, 'reset_credits_available')) {
    merged.reset_credits_available = current.reset_credits_available;
  }
  return merged;
}
function authTokenForCodexAuthRecord(rec) {
  const dir = path.join(codexHome, 'accounts');
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith('.auth.json')).map(f => path.join(dir, f)); } catch { return null; }
  for (const f of files) {
    const obj = readJson(f, null);
    const tok = obj?.tokens?.access_token;
    if (!tok) continue;
    const accountId = obj?.tokens?.account_id || obj?.chatgpt_account_id;
    if (rec?.chatgpt_account_id && accountId === rec.chatgpt_account_id) return tok;
    const info = authInfo(f);
    if (rec?.chatgpt_user_id && rec?.chatgpt_account_id && info.user === rec.chatgpt_user_id && info.account === rec.chatgpt_account_id) return tok;
  }
  return null;
}

function authInfoMatchesRecord(info, rec) {
  if (info?.identityHash && rec?.identity_hash && info.identityHash === rec.identity_hash) return true;
  if (info?.user && info?.account && info.user === rec?.chatgpt_user_id && info.account === rec?.chatgpt_account_id) return true;
  return false;
}

function authTokenForSavedAccount(alias, rec) {
  const rel = rec?.auth_file || path.join('accounts', `${alias}.auth.json`);
  const authPath = path.isAbsolute(rel) ? rel : path.join(acHome, rel);
  if (!fs.existsSync(authPath)) return null;
  const info = authInfo(authPath);
  if (!authInfoMatchesRecord(info, rec)) return null;
  const obj = readJson(authPath, null);
  return obj?.tokens?.access_token || null;
}

async function fetchWhamUsageViaCurl(rec, token, timeoutMs=30000) {
  const tmpDir = path.join(acHome, 'tmp');
  const tmp = path.join(tmpDir, `wham-curl-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.conf`);
  const q = (v) => String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const statusMarker = '__CODEX_HTTP_STATUS__:';
  fs.mkdirSync(tmpDir, { recursive: true, mode: 0o700 });
  const lines = [
    'silent',
    'show-error',
    'location',
    'connect-timeout = 10',
    `max-time = ${Math.max(5, Math.ceil(timeoutMs / 1000))}`,
    ...(usageProxy ? [`proxy = "${q(usageProxy)}"`] : []),
    `url = "${q(whamUsageUrl)}"`,
    `header = "Authorization: Bearer ${q(token)}"`,
    'header = "Accept: application/json"',
    'header = "User-Agent: codex-ac-list/0.8.3"',
    'header = "OpenAI-Beta: codex_cli_beta"',
    `header = "chatgpt-account-id: ${q(rec?.chatgpt_account_id || '')}"`,
    `write-out = "\\n${statusMarker}%{http_code}"`,
  ];
  try {
    fs.writeFileSync(tmp, lines.join('\n') + '\n', { mode: 0o600 });
    const res = await new Promise((resolve, reject) => {
      const child = spawn('curl', ['--config', tmp], { stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '';
      let stderr = '';
      let tooLarge = false;
      let timedOut = false;
      const maxBuffer = 2 * 1024 * 1024;
      const timer = setTimeout(() => {
        timedOut = true;
        child.kill('SIGKILL');
      }, timeoutMs + 5000);
      child.stdout.on('data', chunk => {
        stdout += chunk.toString('utf8');
        if (Buffer.byteLength(stdout) > maxBuffer) {
          tooLarge = true;
          child.kill('SIGKILL');
        }
      });
      child.stderr.on('data', chunk => {
        stderr += chunk.toString('utf8');
        if (Buffer.byteLength(stderr) > maxBuffer) {
          tooLarge = true;
          child.kill('SIGKILL');
        }
      });
      child.once('error', err => {
        clearTimeout(timer);
        reject(err);
      });
      child.once('close', code => {
        clearTimeout(timer);
        if (timedOut) return reject(new Error('curl timeout'));
        if (tooLarge) return reject(new Error('curl response too large'));
        resolve({ status: code, stdout, stderr });
      });
    });
    if (res.status !== 0) throw new Error((res.stderr || `curl exit ${res.status}`).trim().slice(0, 240));
    const markerAt = res.stdout.lastIndexOf(`\n${statusMarker}`);
    if (markerAt < 0) throw new Error('curl response missing HTTP status');
    const body = res.stdout.slice(0, markerAt);
    const status = Number(res.stdout.slice(markerAt + statusMarker.length + 1).trim());
    if (!Number.isFinite(status) || status < 200 || status >= 300) throw new Error(`HTTP ${status || 'unknown'}: ${body.slice(0, 160)}`);
    const data = JSON.parse(body);
    const snap = usageSnapshotFromWham(data);
    if (!snap) throw new Error('no usage windows');
    return snap;
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
}

async function fetchWhamUsageWithToken(rec, token, timeoutMs=30000) {
  if (!token) throw new Error('missing auth token');
  try {
    return await fetchWhamUsageViaCurl(rec, token, timeoutMs);
  } catch (curlError) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetch(whamUsageUrl, {
        method: 'GET',
        signal: ctrl.signal,
        headers: {
          'Authorization': `Bearer ${token}`,
          'Accept': 'application/json',
          'User-Agent': 'codex-ac-list/0.8.3',
          'OpenAI-Beta': 'codex_cli_beta',
          'chatgpt-account-id': rec?.chatgpt_account_id || '',
        },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const snap = usageSnapshotFromWham(data);
      if (!snap) throw new Error('no usage windows');
      return snap;
    } catch (fetchError) {
      throw new Error(`curl failed: ${curlError?.message || curlError}; fetch failed: ${fetchError?.message || fetchError}`);
    } finally {
      clearTimeout(timer);
    }
  }
}

function runCodexAuthRefresh(cmdArgs, timeoutMs=20000) {
  return new Promise(resolve => {
    let settled = false;
    let timer = null;
    const finish = ok => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(ok);
    };
    let child;
    try {
      child = spawn('codex-auth', cmdArgs, { stdio: 'ignore' });
    } catch {
      finish(false);
      return;
    }
    timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(false);
    }, timeoutMs);
    child.once('error', () => finish(false));
    child.once('close', code => finish(code === 0));
  });
}

async function syncCurrentAuthForAlias(alias, dst, nowSec) {
  const currentAuth = path.join(codexHome, 'auth.json');
  if (!fs.existsSync(currentAuth)) return false;
  const info = authInfo(currentAuth);
  if (!authInfoMatchesRecord(info, dst)) return false;
  const obj = readJson(currentAuth, null);
  const token = obj?.tokens?.access_token;
  if (!token) return false;
  const snap = await fetchWhamUsageWithToken(dst, token, 30000);
  const rel = dst.auth_file || path.join('accounts', `${alias}.auth.json`);
  const dstAuth = path.isAbsolute(rel) ? rel : path.join(acHome, rel);
  fs.mkdirSync(path.dirname(dstAuth), { recursive: true, mode: 0o700 });
  fs.copyFileSync(currentAuth, dstAuth);
  try { fs.chmodSync(dstAuth, 0o600); } catch {}
  const authBytes = fs.readFileSync(dstAuth);
  dst.auth_file = path.relative(acHome, dstAuth);
  dst.auth_sha256 = crypto.createHash('sha256').update(authBytes).digest('hex');
  dst.email = info.email || dst.email;
  dst.email_masked = dst.email_masked || dst.email;
  dst.source = 'codex-ac-current-auth-sync';
  dst.updated_at = new Date().toISOString();
  dst.last_usage = snap;
  dst.last_usage_at = nowSec;
  dst.last_reset_credits_at = nowSec;
  if (snap.plan_type) dst.plan = snap.plan_type;
  delete dst.last_usage_error;
  delete dst.last_reset_credits_error;
  return true;
}
async function refreshStaleUsageDirect(reg, maxAgeSec=30) {
  const registryPath = path.join(codexHome, 'accounts', 'registry.json');
  const src = readJson(registryPath, null);
  const records = Array.isArray(src?.accounts) ? src.accounts : (Array.isArray(src?.records) ? src.records : []);
  const nowSec = Math.floor(Date.now() / 1000);
  const byHash = new Map();
  for (const r of records) {
    const h = codexAuthIdentityHash(r);
    if (h) byHash.set(h, r);
  }
  let changed = false;
  const jobs = [];
  for (const [alias, dst] of Object.entries(reg.accounts || {})) {
    if (dst.kind === 'api') continue;
    const usageAge = nowSec - Number(dst.last_usage_at || 0);
    const resetAge = nowSec - Number(dst.last_reset_credits_at || 0);
    const hasResetObservation = Boolean(dst.last_usage && typeof dst.last_usage === 'object'
      && Object.prototype.hasOwnProperty.call(dst.last_usage, 'reset_credits_available'));
    const needsUsage = !Number.isFinite(usageAge) || usageAge < 0 || usageAge >= maxAgeSec;
    const needsReset = !hasResetObservation || !Number.isFinite(resetAge) || resetAge < 0 || resetAge >= maxAgeSec;
    if (!needsUsage && !needsReset) continue;
    jobs.push((async () => {
      try {
        if (await syncCurrentAuthForAlias(alias, dst, nowSec)) {
          changed = true;
          return;
        }
      } catch {}
      let srcRec = dst.identity_hash ? byHash.get(dst.identity_hash) : null;
      if (!srcRec) srcRec = records.find(r => r.chatgpt_user_id === dst.chatgpt_user_id && r.chatgpt_account_id === dst.chatgpt_account_id);
      try {
        let token = srcRec ? authTokenForCodexAuthRecord(srcRec) : null;
        if (!token) token = authTokenForSavedAccount(alias, dst);
        const usageRec = srcRec || dst;
        const snap = await fetchWhamUsageWithToken(usageRec, token, 30000);
        dst.last_usage = snap;
        dst.last_usage_at = nowSec;
        dst.last_reset_credits_at = nowSec;
        if (snap.plan_type) dst.plan = snap.plan_type;
        delete dst.last_usage_error;
        delete dst.last_reset_credits_error;
        changed = true;
      } catch (e) {
        const msg = String(e?.message || e || 'refresh failed');
        if (needsUsage && dst.last_usage_error !== msg) { dst.last_usage_error = msg; changed = true; }
        if (needsReset && dst.last_reset_credits_error !== msg) { dst.last_reset_credits_error = msg; changed = true; }
      }
    })());
  }
  await Promise.all(jobs);
  if (changed) {
    reg.updated_at = new Date().toISOString();
    writeJsonPrivate(path.join(acHome, 'registry.json'), reg);
  }
  return changed;
}

function syncFromCodexAuth(reg) {
  const p = path.join(codexHome, 'accounts', 'registry.json');
  const src = readJson(p, null);
  const records = Array.isArray(src?.accounts) ? src.accounts : (Array.isArray(src?.records) ? src.records : []);
  const byHash = new Map();
  for (const r of records) {
    const h = codexAuthIdentityHash(r);
    if (h) byHash.set(h, r);
  }
  let changed = false;
  for (const [alias, dst] of Object.entries(reg.accounts || {})) {
    let srcRec = dst.identity_hash ? byHash.get(dst.identity_hash) : null;
    if (!srcRec) {
      srcRec = records.find(r => r.chatgpt_user_id === dst.chatgpt_user_id && r.chatgpt_account_id === dst.chatgpt_account_id);
    }
    if (!srcRec) continue;
    const srcUsageAt = Number.isFinite(Number(srcRec.last_usage_at)) ? Number(srcRec.last_usage_at) : 0;
    const dstUsageAt = Number.isFinite(Number(dst.last_usage_at)) ? Number(dst.last_usage_at) : 0;
    const acceptSourceUsage = srcRec.last_usage !== undefined
      && (!dst.last_usage || srcUsageAt >= dstUsageAt);
    if (acceptSourceUsage) {
      const mergedUsage = mergeUsageSnapshots(dst.last_usage, srcRec.last_usage);
      if (JSON.stringify(dst.last_usage) !== JSON.stringify(mergedUsage)) { dst.last_usage = mergedUsage; changed = true; }
      if (Object.prototype.hasOwnProperty.call(srcRec.last_usage || {}, 'reset_credits_available')
          && srcRec.last_reset_credits_at === undefined && srcRec.last_usage_at !== undefined
          && dst.last_reset_credits_at !== srcRec.last_usage_at) {
        dst.last_reset_credits_at = srcRec.last_usage_at;
        changed = true;
      }
      if (srcRec.last_usage_at !== undefined && dst.last_usage_at !== srcRec.last_usage_at) {
        dst.last_usage_at = srcRec.last_usage_at;
        changed = true;
      }
    }
    if (Object.prototype.hasOwnProperty.call(srcRec.last_usage || {}, 'reset_credits_available')
        && srcRec.last_reset_credits_at !== undefined
        && Number(srcRec.last_reset_credits_at) >= Number(dst.last_reset_credits_at || 0)
        && dst.last_reset_credits_at !== srcRec.last_reset_credits_at) {
      dst.last_reset_credits_at = srcRec.last_reset_credits_at;
      changed = true;
    }
    for (const k of ['last_local_rollout','last_used_at']) {
      if (srcRec[k] !== undefined && JSON.stringify(dst[k]) !== JSON.stringify(srcRec[k])) { dst[k] = srcRec[k]; changed = true; }
    }
    if (srcRec.plan && dst.plan !== srcRec.plan) { dst.plan = srcRec.plan; changed = true; }
    if (acceptSourceUsage && dst.last_usage_error !== undefined) { delete dst.last_usage_error; changed = true; }
  }
  if (changed) { reg.updated_at = new Date().toISOString(); writeJsonPrivate(path.join(acHome, 'registry.json'), reg); }
  return changed;
}
function maskEmail(email) {
  if (!email || !email.includes('@')) return '<unknown>';
  const [l,d] = email.split('@');
  const lm = l.length <= 2 ? `${l[0] || '*'}*` : `${l[0]}***${l[l.length-1]}`;
  return `${lm}@${d}`;
}
function asInt(v) { return Number.isFinite(v) ? Math.trunc(v) : null; }
function windowMatchesMinutes(win, expectedMinutes) {
  const actualMinutes = asInt(win?.window_minutes);
  if (actualMinutes === null) return false;
  return Math.abs(actualMinutes - expectedMinutes) <= Math.max(1, Math.trunc(expectedMinutes / 4));
}
function resetParts(ts) {
  const dt = new Date(ts * 1000); const now = new Date();
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const hh = String(dt.getHours()).padStart(2,'0'); const mm = String(dt.getMinutes()).padStart(2,'0');
  const same = dt.getFullYear()===now.getFullYear() && dt.getMonth()===now.getMonth() && dt.getDate()===now.getDate();
  return { time: `${hh}:${mm}`, date: `${dt.getDate()} ${months[dt.getMonth()]}`, same };
}
function windowFor(snap, minutes, fallbackPrimary) {
  if (!snap) return null;
  const p = snap.primary, s = snap.secondary;
  for (const w of [p,s]) if (w && windowMatchesMinutes(w, minutes)) return w;
  const fallback = fallbackPrimary ? p : s;
  return fallback && asInt(fallback.window_minutes) === null ? fallback : null;
}
function fiveHourIsUnlimited(snap) {
  if (!snap || windowFor(snap, 300, true)) return false;
  return Boolean(windowFor(snap, 10080, false));
}
function fmtUsage(snap, minutes, fallbackPrimary) {
  if (minutes === 300 && fiveHourIsUnlimited(snap)) return '∞';
  const w = windowFor(snap, minutes, fallbackPrimary);
  if (!w || !Number.isFinite(w.used_percent) || !w.resets_at) return '-';
  const now = Math.floor(Date.now()/1000);
  if (w.resets_at <= now) return '100%';
  let rem = 100 - Number(w.used_percent); rem = rem <= 0 ? 0 : rem >= 100 ? 100 : Math.trunc(rem);
  const rp = resetParts(w.resets_at);
  return rp.same ? `${rem}% (${rp.time})` : `${rem}% (${rp.time} on ${rp.date})`;
}
function normalizeUsageError(err) {
  const s = String(err || '');
  if (/refresh_token_reused|token_expired|Provided authentication token is expired|HTTP 401|401 Unauthorized/i.test(s)) return '登录过期';
  if (/RequestFailed|fetch failed|curl failed|ENOTFOUND|ETIMEDOUT|ECONNRESET|timeout/i.test(s)) return '刷新失败';
  return s ? '刷新失败' : '';
}
function usageCell(rec, usage, minutes, fallbackPrimary) {
  const label = normalizeUsageError(rec?.last_usage_error);
  if (label) return label;
  return fmtUsage(usage, minutes, fallbackPrimary);
}
function resetCreditsCell(rec) {
  if (!cached && rec?.last_reset_credits_error) return '?';
  const value = nonNegativeInt(rec?.last_usage?.reset_credits_available);
  return value === null ? '?' : String(value);
}
function fmtLast(ts) {
  if (!ts || ts <= 0) return '-';
  let d = Math.floor(Date.now()/1000) - ts; if (d < 0) d = 0;
  if (d < 60) return 'Now'; if (d < 3600) return `${Math.trunc(d/60)}m ago`; if (d < 86400) return `${Math.trunc(d/3600)}h ago`; return `${Math.trunc(d/86400)}d ago`;
}
function pad(s,n){ s=String(s); return s + ' '.repeat(Math.max(0,n-s.length)); }

const regPath = path.join(acHome, 'registry.json');
let reg = readJson(regPath, { accounts: {}, active_alias: null });
if (!cached) {
  const syncKey = api && !skipApi ? 'last_codex_auth_api_sync_at' : 'last_codex_auth_local_sync_at';
  const nowSec = Math.floor(Date.now() / 1000);
  const ttlSec = api && !skipApi ? 0 : 5;
  const lastSync = Number.isFinite(reg[syncKey]) ? reg[syncKey] : 0;
  const shouldRunNative = ttlSec === 0 || !lastSync || nowSec - lastSync >= ttlSec;
  let nativeRefresh = Promise.resolve(false);
  if (shouldRunNative) {
    const cmdArgs = api && !skipApi ? ['list'] : ['list','--skip-api'];
    nativeRefresh = runCodexAuthRefresh(cmdArgs);
    reg[syncKey] = nowSec;
    writeJsonPrivate(regPath, reg);
  }
  await Promise.all([nativeRefresh, refreshStaleUsageDirect(reg)]);
  syncFromCodexAuth(reg);
  reg = readJson(regPath, reg);
}
const accounts = reg.accounts || {};
if (Object.keys(accounts).length === 0) { console.log('暂无账号。先执行：codex-ac add <alias> 或 codex-ac import-codex-auth'); process.exit(0); }
const active = currentAlias(reg) || reg.active_alias;
const sorted = Object.entries(accounts).sort(([a],[b]) => (a===active?0:1)-(b===active?0:1) || a.localeCompare(b));
const idxWidth = Math.max(2, String(sorted.length).length);
const rows = sorted.map(([alias,rec], i) => {
  const usage = rec.last_usage || null;
  const isApi = rec.kind === 'api';
  const email = isApi
    ? `api:${(rec.base_url || rec.provider_id || alias).replace(/^https?:\/\//,'')}`
    : (maskAccount ? (rec.email_masked || maskEmail(rec.email)) : (rec.email || rec.email_masked || '<unknown>'));
  return {
    marker: alias===active ? '*' : ' ',
    num: String(i + 1).padStart(idxWidth, '0'),
    alias,
    account: email,
    plan: isApi ? 'API' : (rec.plan ? String(rec.plan)[0].toUpperCase()+String(rec.plan).slice(1) : '-'),
    h5: isApi ? '-' : usageCell(rec, usage,300,true),
    weekly: isApi ? '-' : usageCell(rec, usage,10080,false),
    resetCredits: isApi ? '-' : resetCreditsCell(rec),
    updated: isApi ? (rec.last_switched_at ? 'switched' : '-') : fmtLast(rec.last_usage_at),
    active: alias===active,
  };
});
const accountWidth = Math.max('ACCOUNT'.length, ...rows.map(r => r.account.length));
const planWidth = Math.max('PLAN'.length, ...rows.map(r => r.plan.length));
const h5Width = Math.max('5H USAGE'.length, ...rows.map(r => r.h5.length));
const weeklyWidth = Math.max('WEEKLY USAGE'.length, ...rows.map(r => r.weekly.length));
const resetCreditsWidth = Math.max('RESET'.length, ...rows.map(r => r.resetCredits.length));
const updatedWidth = Math.max('UPDATED'.length, ...rows.map(r => r.updated.length));
const aliasWidth = showAlias ? Math.max('ALIAS'.length, ...rows.map(r => r.alias.length)) : 0;
const c = { reset: '\x1b[0m', green: '\x1b[32m', dim: '\x1b[90m' };
function color(text, kind) {
  if (!useColor) return text;
  return `${c[kind]}${text}${c.reset}`;
}
let header = `${' '.repeat(3 + idxWidth)}${pad('ACCOUNT', accountWidth)}  ${pad('PLAN', planWidth)}  ${pad('5H USAGE', h5Width)}  ${pad('WEEKLY USAGE', weeklyWidth)}  ${pad('RESET', resetCreditsWidth)}  ${pad('UPDATED', updatedWidth)}`;
if (showAlias) header += `  ${pad('ALIAS', aliasWidth)}`;
const sep = '-'.repeat(header.length);
console.log(color(header, 'dim'));
console.log(color(sep, 'dim'));
for (const r of rows) {
  let line = `${r.marker} ${r.num} ${pad(r.account, accountWidth)}  ${pad(r.plan, planWidth)}  ${pad(r.h5, h5Width)}  ${pad(r.weekly, weeklyWidth)}  ${pad(r.resetCredits, resetCreditsWidth)}  ${pad(r.updated, updatedWidth)}`;
  if (showAlias) line += `  ${pad(r.alias, aliasWidth)}`;
  console.log(color(line, r.active ? 'green' : 'dim'));
}
const staleRefreshFailures = sorted
  .filter(([, rec]) => rec.kind !== 'api' && rec.last_usage_error && rec.last_usage_at)
  .map(([alias, rec]) => {
    const ageSec = Math.max(0, Math.floor(Date.now() / 1000) - Number(rec.last_usage_at || 0));
    return { alias, ageSec, err: String(rec.last_usage_error).replace(/\s+/g, ' ').slice(0, 180) };
  })
  .filter(x => Number.isFinite(x.ageSec) && x.ageSec >= 300);
if (staleRefreshFailures.length && !cached) {
  const summary = staleRefreshFailures.map(x => {
    const reason = normalizeUsageError(x.err);
    return `${x.alias} ${reason || '刷新失败'}(${fmtLast(Math.floor(Date.now() / 1000) - x.ageSec)})`;
  }).join(', ');
  const loginExpired = staleRefreshFailures.some(x => normalizeUsageError(x.err) === '登录过期');
  const action = loginExpired ? '需要重新登录对应账号，例如 ca r fox；要重登后立刻切换，用 ca r fox --switch。' : '可运行 ca ll --cached 查看缓存，或 ca ll --alias 看别名。';
  console.error(`warning: usage refresh failed: ${summary}. ${action}`);
}
