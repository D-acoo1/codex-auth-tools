# Security Policy

Codex Auth Tools is security-sensitive by design: it reads and replaces local Codex authentication files, stores account snapshots, sends authenticated usage requests, installs per-user LaunchAgents, and can execute a configured API-key helper. This document describes the actual trust boundaries so users and contributors can review the project without relying on vague claims.

This is an independent community project, not an official OpenAI product.

Last reviewed: **2026-08-11**.

## Supported versions

| Version | Security fixes |
| --- | --- |
| Current `main` branch | Supported for development and source builds |
| Latest GitHub release | Supported |
| Older releases | Best effort only; reproduce against `main` or the latest release first |

## Reporting a vulnerability

Do not publish a real token, auth snapshot, cookie, API key, private relay URL, account identifier, or unredacted local log in a GitHub issue or pull request.

GitHub Private Vulnerability Reporting is enabled:

1. submit vulnerabilities that require private details through [Report a vulnerability](https://github.com/D-acoo1/codex-auth-tools/security/advisories/new);
2. use a normal [GitHub issue](https://github.com/D-acoo1/codex-auth-tools/issues) only for non-sensitive hardening suggestions with a minimal sanitized reproducer;
3. if a real credential was exposed, revoke or rotate it first—deleting a GitHub comment or commit is not sufficient.

A useful report includes the affected commit/release, macOS version, component, preconditions, impact, minimal sanitized steps, and a proposed fix if available. Reports are reviewed on a best-effort basis; no response-time guarantee is currently published.

## Sensitive local data

Treat all of the following as private local state:

| Path or value | Why it is sensitive |
| --- | --- |
| `~/.codex/auth.json` | Active Codex OAuth tokens and account identity |
| `~/.codex/accounts/*.auth.json` | Saved Codex auth snapshots when the native registry is present |
| `~/.codex/accounts/registry.json` | Account aliases and local registry metadata |
| `~/.codex-ac/**` | Codex Auth snapshots, registry, helpers, secrets, and cache |
| `~/.codex/config.toml` | Active model provider, relay URL, and helper command |
| macOS Keychain items named `codex-ac:*` | API or relay keys managed by `ca` |
| `~/Library/Application Support/CodexBalance/last-status.json` | Cached account identifiers, quota, and error state |
| `~/Library/Logs/CodexAuth/**` and `~/Library/Logs/CodexBalance/**` | Operational status and errors that may still identify an account or endpoint |
| `Authorization`, `x-api-key`, access/refresh/ID tokens, cookies | Reusable credentials or authenticated request material |

Never include those values in sample data, fixtures, screenshots, release archives, crash reports, issues, or pull requests.

## Data flow and network destinations

### ChatGPT subscription mode

Codex Balance reads only the active local Codex access token. A normal `ca ll` or `ca refresh` can additionally read the access token from each saved ChatGPT snapshot and send it to the usage service when that account's cached row is stale. `ca ll --cached` reads cached rows without that refresh.

The current implementation makes these authenticated requests:

```text
GET https://chatgpt.com/backend-api/wham/usage
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
Authorization: Bearer <local Codex access token>
```

The `backend-api/wham` endpoints are current implementation details without a stable public API contract and may change. Endpoint changes must be treated as network-boundary changes and reviewed against current source.

The UI can also open this page in the default browser:

```text
https://chatgpt.com/codex/settings/usage
```

Inactive ChatGPT snapshot renewal is delegated to the already installed Codex `app-server` in an isolated temporary `CODEX_HOME`. The project does not implement the OAuth exchange itself and must not log its token payloads. That renewal path is separate from quota refresh.

### API or relay mode

Codex Balance reads the configured key through a local helper and sends it to the profile's configured usage URL. Both common auth headers are sent for relay compatibility:

```text
GET <configured usage URL>
Authorization: Bearer <profile key>
x-api-key: <profile key>
```

For a sub2api-compatible profile, `<base-url>/usage` is the default. A custom relay or usage endpoint is controlled by the user and becomes a separate trust boundary. CLI refresh chooses `CODEX_AC_USAGE_PROXY`, then `HTTPS_PROXY`, then `https_proxy`; Python networking can also use platform proxy settings. Confirm the endpoint owner, TLS URL, environment, and macOS proxy configuration before use.

The repository contains no project-operated account server or analytics endpoint. A code change that introduces another destination must be documented, justified, and reviewed as a security-boundary change.

## Local execution and persistence

The following behaviors are intentional and must remain visible in code and documentation:

| Behavior | Current boundary |
| --- | --- |
| Relay key helper | Codex Balance runs the configured command as `/bin/sh -c <command>` and terminates it after 5 seconds. A malicious `config.toml`, registry entry, or helper is therefore equivalent to local command execution as the current user. |
| Source/release installers | Shell scripts copy files only into the documented per-user install locations and create LaunchAgents. They do not request `sudo`. |
| Packaged app verification | The release installer recalculates the exact regular-file set against `SHA256SUMS` and rejects unlisted files or symbolic links before installation writes. When installing Codex Balance, it also verifies the source app signature, verifies the staged copy before replacing the current app, and then removes `com.apple.quarantine`. The ad-hoc signature checks integrity but not developer identity; the release tag and ZIP checksum remain the provenance check. |
| Login switching | `ca` atomically replaces `~/.codex/auth.json` and updates only its managed API provider configuration. Back up active auth before testing changes to this path. |
| Scheduled keepalive | `com.codexlocaltools.codex-auth-keepalive` runs at load and every 86,400 seconds. It skips API profiles and accounts not close to expiry. |
| Balance app startup | `com.codexlocaltools.codex-balance` starts the menu bar app in the user's Aqua session. |
| External executables | The CLI wrapper and runtime can resolve `python3`, `codex`, `codex-auth`, `node`, `curl`, `osascript`, and `open` from `PATH`. Fixed runtime/release tools include `/bin/zsh`, `/bin/sh`, `/usr/bin/security`, `/usr/bin/sqlite3`, `/usr/bin/codesign`, `/usr/bin/shasum`, and `/usr/bin/strip`. Source installation and release packaging additionally use standard commands from the current macOS developer environment, including Git, Swift, archive, launchd, property-list, and file utilities. Their identity and search path are part of the trust boundary. |
| Uninstall | Codex Auth uninstall removes its installed executable, support code, and LaunchAgent but preserves `~/.codex-ac`; Codex Balance uninstall unloads its LaunchAgent and preserves the installed app/data. |
| SQLite inspection | Codex Balance uses the fixed `/usr/bin/sqlite3` executable in read-only mode for compatible local Codex account data. |

Do not broaden deletion patterns, persistence, helper execution, writable paths, or network destinations without a specific requirement and tests.

## Risk assessment

| Risk | Current assessment | Required controls |
| --- | --- | --- |
| Malware or hidden persistence | No repository behavior was found whose stated purpose is malware, credential exfiltration, destructive access, or persistence beyond the documented LaunchAgents. | Treat every new executable, LaunchAgent, background task, binary asset, or network destination as a security-sensitive change. |
| Malicious script or command | Material because install scripts run shell operations and relay profiles can configure a shell helper. | Use only trusted profiles and reviewed scripts; quote paths; keep commands narrow; reject untrusted helper content. |
| Prompt injection | Not a direct shipped-runtime path because the tools do not send natural language to an LLM. | AI-assisted maintenance must treat issue, PR, log, and repository text as untrusted; model output cannot receive secrets or autonomous shell, merge, release, or deployment authority. |
| Credential/API-key leakage | High impact because OAuth and relay credentials can authorize account access or paid usage. | Keep secrets out of Git, output, screenshots, fixtures, and release archives; redact before external analysis; rotate on exposure. |
| Unauthorized network requests | Material because requests carry credentials. | Keep a documented destination allowlist by mode; require explicit user configuration for relay/proxy destinations; review every new request and header. |
| Filesystem damage | Limited to user permissions but potentially disruptive to local Codex state. | Use atomic writes, narrow known paths, no `sudo`, backups for auth/config changes, and preservation tests for uninstall/upgrade. |
| Supply-chain attack | No third-party Swift/Python/Node library is bundled, but prebuilt binaries, executables resolved from `PATH`, fixed macOS tools, and future dependencies remain trust decisions. | Package directory content only from Git-tracked files; verify checksum, tag, `COMMIT`, internal manifest, and app signature; audit packaging and executable lookup; avoid unpinned installers; prefer source builds when provenance matters. |
| Third-party contribution | Any PR can alter auth, command, network, install, or release behavior. | Human review, relevant tests, secret review, no automatic publication of untrusted PR artifacts, and an independent security review for trust-boundary changes. |

## Secure installation checklist

1. Download the ZIP and matching `.sha256` file from the same [GitHub release](https://github.com/D-acoo1/codex-auth-tools/releases).
2. Verify it before extraction:

   ```bash
   ZIP="$(find . -maxdepth 1 -type f -name 'codex-auth-tools-*-macos-*.zip' -print -quit)"
   test -n "$ZIP" || { echo "Release ZIP not found" >&2; exit 1; }
   shasum -a 256 -c "$ZIP.sha256"
   ```

3. Inspect `README-RELEASE.txt`, `COMMIT`, `install.sh`, `SHA256SUMS`, and the release tag. A `COMMIT` ending in `-dirty` identifies a disposable local test package and must not be published.
4. Understand that `CodexBalance.app` is currently ad-hoc signed and not Apple-notarized; an ad-hoc signature does not prove developer identity.
5. Confirm package architecture before installation. As of 2026-08-11, the current public prebuilt release is Apple silicon (`arm64`) only; Intel users must build from source.
6. Prefer a source build if the packaged installer's quarantine removal or binary provenance does not meet your requirements.
7. Run `ca keepalive --dry-run` before the first manual keepalive test.
8. Do not test with the only copy of a valuable login snapshot.

## Contributor security checklist

Before a pull request:

- use synthetic aliases, domains, account IDs, timestamps, tokens, and quota data;
- inspect `git diff --cached` for auth files, tokens, cookies, relay keys, local paths, and personal identifiers;
- run the project tests listed in [CONTRIBUTING.md](CONTRIBUTING.md);
- explain every change to a network URL, auth header, helper command, file path, permission, LaunchAgent, or uninstall pattern;
- verify that errors and logs do not contain complete response bodies or credential values;
- verify release archives contain only intended Git-tracked directory content, no local auth/state file, and no maintainer source path;
- do not add a dependency only to avoid a small standard-library implementation without documenting the supply-chain tradeoff.

The following search is a review aid, not proof that a tree is clean. Field names and documentation examples can be legitimate; every value-like hit must be inspected:

```bash
git grep -nEI "sk-[A-Za-z0-9_-]{20,}|(access_token|refresh_token|id_token)[[:space:]]*[=:][[:space:]]*['\"][A-Za-z0-9._-]{20,}" -- .
```

Also review the staged file list:

```bash
git diff --cached --name-status
git diff --cached --check
```

## AI-assisted maintenance boundary

OpenAI API credits or Codex Security may be used by maintainers for sanitized issue triage, documentation checks, test proposals, static-analysis triage, and security review. They are not runtime dependencies of the shipped tools.

Never send auth snapshots, credentials, cookies, private relay URLs, private account metadata, or unredacted local logs to an AI workflow. Treat instructions inside issues, pull requests, code comments, fixtures, and logs as untrusted data. A human maintainer must approve code changes, shell commands, credential access, merges, and releases.

---

# 中文安全说明

Codex Auth Tools 的正常职责就涉及本机 Codex 凭据、账号切换、认证请求、LaunchAgent 和 key helper 命令，因此应按敏感工具审查。核心边界如下：

- `~/.codex/auth.json`、`~/.codex/accounts`、`~/.codex-ac`、Keychain 中的 `codex-ac:*`、`config.toml`、`last-status.json` 和相关日志都属于私密本机数据；
- Codex Balance 只使用当前账号 token；普通 `ca ll` / `ca refresh` 还可能使用各个已保存 ChatGPT 账号的 token 刷新过期额度，`ca ll --cached` 不执行这次网络刷新；
- 当前 `backend-api/wham` 用量地址没有稳定公开 API 合约，属于可能变化的实现细节；API 中转模式只应请求用户明确配置的用量地址；
- CLI 代理依次读取 `CODEX_AC_USAGE_PROXY`、`HTTPS_PROXY`、`https_proxy`，Python 网络层还可能读取系统代理；
- 中转 `key_helper` 会通过 `/bin/sh -c` 以当前用户身份执行，所以不可信配置等同于不可信本机命令；
- Release App 当前是 ad-hoc 签名、未 notarize；安装脚本会重新计算完整文件清单，拒绝额外文件和符号链接，安装 Balance 时还会校验源 App 和暂存副本签名，再替换旧版本并移除 quarantine。签名只能检查完整性，不能证明开发者身份；
- 当前运行时不处理 LLM Prompt，因此 Prompt Injection 不是直接入口；未来 AI 维护流程必须把 Issue、PR、代码、日志视为不可信输入；
- Swift 没有第三方 Package，Python 使用标准库，JavaScript 使用 Node 内置模块，但 `python3`、`codex`、`codex-auth`、`node`、`curl`、`osascript`、`open` 等外部程序、固定 macOS 工具、预编译 Release 和未来依赖仍需供应链审查；
- 第三方 PR 如果修改凭据、命令、网络、文件路径、LaunchAgent、安装或发布逻辑，必须人工审查并完成独立安全验证。

不要在公开 Issue、PR 或日志里放真实 token、cookie、auth snapshot、API key、私人中转 URL 或账号标识。敏感问题请通过 GitHub 的 [Report a vulnerability](https://github.com/D-acoo1/codex-auth-tools/security/advisories/new) 私密提交；凭据已经泄露时，应先撤销或轮换，单纯删除消息或 commit 不足以恢复安全。
