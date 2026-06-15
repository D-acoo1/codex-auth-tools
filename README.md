# Codex Local Tools

A small local toolkit for people who use Codex with multiple ChatGPT/Codex accounts.

This repository contains two tools:

| Tool | Command / app | Purpose |
| --- | --- | --- |
| Codex Balance | `CodexBalance` | macOS menu bar widget that shows the current Codex account quota. |
| Codex Auth | `ca`, `codex-ac` | Local Codex account manager for switching and inspecting saved Codex auth snapshots. |

The tools read local Codex login state from `~/.codex`. They do **not** include any account, token, cookie, or personal cache data.

## Repository layout

```text
codex-local-tools/
  codex-balance/          # Swift/AppKit menu bar widget
  codex-auth/             # ca / codex-ac account manager
  docs/                   # detailed docs
  scripts/                # install helpers
```

## Codex Balance

Codex Balance is a lightweight macOS status bar app. It reads the active Codex OAuth login from `~/.codex/auth.json`, calls the Codex usage endpoint, and displays:

- 5-hour quota remaining
- weekly quota remaining
- account alias and email
- plan and availability
- Credits
- Spark remaining quota
- reset countdown and reset time

It refreshes every 30 seconds. Opening the popover or clicking refresh updates immediately. If you switch accounts with `ca s <alias>`, the widget follows the new `~/.codex/auth.json` on the next refresh.

### Build and install

```bash
./scripts/install-codex-balance.sh
```

The default install path is:

```text
~/Library/Application Support/CodexBalance/CodexBalance
```

The default LaunchAgent label is:

```text
com.codexlocaltools.codex-balance
```

To use a custom LaunchAgent label:

```bash
CODEX_BALANCE_LAUNCHD_LABEL=com.example.codex-balance ./scripts/install-codex-balance.sh
```

## Codex Auth (`ca`)

Codex Auth is a local account manager for Codex auth snapshots. It can:

- import the current `~/.codex/auth.json`
- switch active accounts by replacing `~/.codex/auth.json`
- list saved accounts and cached quota usage
- add API-compatible providers
- run Codex with an isolated account home

### Install

```bash
./scripts/install-codex-auth.sh
```

Commands:

```bash
ca --help
ca ll
ca current
ca s <alias>
```

`ca` stores account snapshots under `~/.codex-ac` by default. Auth snapshots are private local files and must never be committed.

## Usage endpoint

Both tools use the current local Codex login to read usage data from:

```text
https://chatgpt.com/backend-api/wham/usage
```

The endpoint currently returns quota percentages, reset times, plan type, Credits, and additional rate limits such as Spark. It does not provide a reliable membership expiration date, so the tools do not display one.

## Proxy

`codex-auth` can optionally use a proxy for usage refresh:

```bash
CODEX_AC_USAGE_PROXY=http://localhost:8080 ca ll
```

If no proxy is set, it tries the direct request path.

## Security notes

- Do not commit `~/.codex/auth.json`, `~/.codex/accounts/*.auth.json`, or `~/.codex-ac`.
- Do not publish `last-status.json` if it contains personal account identifiers.
- The repository `.gitignore` blocks common local auth and state files.
- The tools operate only on local files and the current Codex usage endpoint.

## License

MIT.
