# Contributing to Codex Auth Tools

Thank you for improving Codex Auth Tools. This project accepts focused issues and pull requests for Codex Auth, Codex Balance, localization, documentation, tests, packaging, and security hardening.

Because the project handles local credentials and can execute per-user helper commands, a change that appears small can still alter a trust boundary. Correctness, explicit behavior, and reproducible evidence take priority over adding more features.

## Before starting

1. Search existing [issues](https://github.com/D-acoo1/codex-auth-tools/issues) and pull requests.
2. For a substantial new workflow, open a sanitized issue describing the user problem and expected behavior before writing a large patch.
3. Read [SECURITY.md](SECURITY.md) before changing authentication, storage, commands, network requests, LaunchAgents, install/uninstall logic, or release packaging.
4. Never use a real credential, auth snapshot, account identifier, relay key, private endpoint, or unredacted local log as a fixture.

## Development environment

The supported application target is macOS 13 or later. Typical development requirements are:

- Xcode Command Line Tools with Swift 6 support;
- Python 3;
- Node.js for the optional Node-based account list renderer;
- Bash and standard macOS command-line tools.

Clone and inspect the repository:

```bash
git clone https://github.com/D-acoo1/codex-auth-tools.git
cd codex-auth-tools
git status --short --branch
```

Do not point development builds at the only copy of a valuable `~/.codex/auth.json`. The existing black-box tests create temporary homes and synthetic state; follow that pattern for new tests.

## Repository areas

| Area | Responsibility |
| --- | --- |
| `codex-auth/` | Python/Node `ca` account manager and usage list renderer |
| `codex-balance/` | Swift/AppKit menu bar app, usage parsing, localization, and UI |
| `scripts/` | Source installation, uninstall, and reproducible release packaging |
| `tests/` | CLI/keepalive black-box and regression tests |
| `docs/`, `README.md`, `SECURITY.md` | Public behavior, trust boundaries, and maintenance instructions |

Keep changes narrow. Prefer a root-cause fix and a regression test over a fallback that hides incorrect state.

## Required verification

Run the checks relevant to the changed files. A normal full verification is:

```bash
swift build --package-path codex-balance
python3 tests/keepalive-auth.py
bash tests/blackbox-ca-balance.sh
git diff --check
```

Also review changed Markdown links and anchors when documentation moves. A documentation-only pull request does not need an unrelated release build, but it must still pass `git diff --check` and must not describe behavior that the source does not implement.

`tests/keepalive-auth.py` uses the operating system temporary directory by default. Set `CODEX_AUTH_TEST_TMPDIR` to an existing disposable directory when test artifacts must stay on a specific volume; do not hard-code a maintainer path in the repository.

For release-packaging changes, build into a disposable directory and inspect the archive before publishing:

```bash
DIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-auth-tools-release.XXXXXX")/release"
export DIST_DIR
ALLOW_DIRTY_RELEASE=1 ./scripts/package-release.sh v0.0.0-test
find "$DIST_DIR" -maxdepth 2 -type f -print
```

`ALLOW_DIRTY_RELEASE=1` is only for disposable local verification and writes `<commit>-dirty` to `COMMIT`; never publish such a package. A publishable release build must start from a clean worktree. Directory content is copied only from Git-tracked files. The archive must not contain source-machine paths, local account state, tokens, cookies, private endpoints, ignored local files, symbolic links, or personal screenshots. Verify its checksum, `COMMIT`, exact included `SHA256SUMS` manifest, app architecture, and app signature.

## Security-sensitive changes

Explicitly call out any change to:

- credential parsing, storage, copying, renewal, or deletion;
- auth headers, URLs, redirects, proxies, response logging, or complete response bodies;
- `/bin/sh -c`, `Process`, `subprocess`, helper commands, or executable lookup;
- writable paths, permissions, atomic replacement, backups, or deletion patterns;
- LaunchAgents, background intervals, startup behavior, or hidden persistence;
- Keychain access or fallback secret files;
- packaging, signatures, quarantine handling, checksums, or dependencies.

The pull request must explain the old boundary, the new boundary, why the change is needed, and how it was verified. Do not auto-publish artifacts built from an unreviewed fork or pull request.

## Documentation and localization

- Keep the English and Chinese README sections consistent for user-visible behavior and security boundaries.
- Use synthetic domains such as `relay.example.com` and clearly fake aliases.
- Update `docs/codex-auth.md` or `docs/codex-balance.md` when component behavior changes.
- Update `SECURITY.md` when a network destination, credential path, helper command, persistent process, dependency, signing model, or release trust boundary changes.
- Do not advertise a feature, official affiliation, security certification, or program access that has not been verified.

README UI samples must come from the production AppKit view instead of a hand-drawn approximation. After a visible Codex Balance layout or localization change, regenerate the English panel, Simplified Chinese panel, and matching status-bar image with synthetic data:

```bash
./scripts/render-readme-samples.sh
```

Review both panel images before committing them. The renderer uses the same `CodexPanelViewController`, card drawing code, labels, controls, and status title as the app, keeps animation off, and never reads a real auth snapshot.

## Pull request requirements

A useful pull request contains:

1. the user-visible problem;
2. the root cause or source of truth;
3. a concise description of the change;
4. test commands and exact results;
5. screenshots for visible UI changes, using synthetic account data;
6. security and compatibility impact;
7. a rollback description when state or install behavior changes.

Keep generated build products, local logs, `.codex*` data, Swift build directories, release archives, and personal screenshots out of Git.

## Security reports

Do not open a public issue containing a workable exploit or secret. Use GitHub [Private Vulnerability Reporting](https://github.com/D-acoo1/codex-auth-tools/security/advisories/new) as described in [SECURITY.md](SECURITY.md). If a credential is already exposed, revoke or rotate it before doing anything else.

---

# 中文贡献说明

本项目接受针对 `ca`、Codex Balance、本地化、文档、测试、打包和安全加固的聚焦贡献。由于工具会处理本机凭据并可能执行 helper command，涉及认证、网络、命令、文件、LaunchAgent、Keychain、安装/卸载或 Release 的改动必须明确说明旧边界、新边界、改动原因和验证结果。

提交前至少执行：

```bash
swift build --package-path codex-balance
python3 tests/keepalive-auth.py
bash tests/blackbox-ca-balance.sh
git diff --check
```

测试和截图只能使用示例账号、示例域名与伪造额度；禁止提交真实 auth snapshot、token、cookie、API key、私人中转地址、账号标识或未脱敏日志。打包改动可用 `ALLOW_DIRTY_RELEASE=1` 生成一次性测试包，但 `COMMIT` 带 `-dirty` 的包禁止发布，正式 Release 必须从干净工作区构建。可复现的敏感漏洞不要公开发 Issue，请通过 GitHub [Private Vulnerability Reporting](https://github.com/D-acoo1/codex-auth-tools/security/advisories/new) 私密提交。

`tests/keepalive-auth.py` 默认使用系统临时目录；如需把测试产物放到指定磁盘，设置 `CODEX_AUTH_TEST_TMPDIR` 为已存在的一次性目录，不要在仓库里写死维护者路径。

README 界面图禁止手工仿画。Codex Balance 的布局或本地化发生可见变化后，执行 `./scripts/render-readme-samples.sh`，由生产 `CodexPanelViewController` 直接生成英文、简体中文面板和对应状态栏图；提交前必须检查两张面板图，渲染过程只使用伪造账号数据，不读取真实登录快照。
