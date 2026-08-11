# Codex Balance

Codex Balance is a macOS menu bar widget implemented in Swift/AppKit.

## Data flow

For ChatGPT subscription accounts, Codex Balance reads only the active account:

1. Read the active auth from `~/.codex/auth.json`.
2. Use `tokens.access_token` as a bearer token.
3. Fetch `https://chatgpt.com/backend-api/wham/usage`.
4. Render quota information in the status bar and popover.
5. Write a local debug/status snapshot to `~/Library/Application Support/CodexBalance/last-status.json`.

For API or relay accounts selected by `ca s <alias>`:

1. Read the active provider from `~/.codex/config.toml`.
2. Match it to the API account in `~/.codex-ac/registry.json`.
3. Read the API key through the private helper command.
4. Fetch the relay usage endpoint, defaulting to `<base-url>/usage`.
5. Render relay balance, cost, token usage, and request count when the endpoint supports them.
6. Never display the API key.

For sub2api-compatible relays, `https://relay.example.com/v1` maps to:

```text
GET https://relay.example.com/v1/usage
```

The relay key-helper command is executed through `/bin/sh -c` with a 5-second timeout. Only helpers generated locally by `ca` or commands that have been independently reviewed should be used. The configured usage service receives the key in both `Authorization: Bearer` and `x-api-key` headers.

For ChatGPT subscription accounts, the only authenticated service destinations in the current source are:

```text
https://chatgpt.com/backend-api/wham/usage
https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

These `backend-api/wham` URLs are current implementation details without a stable public API contract and may change. The app does not send credentials to a project-operated analytics or account server. Custom relay configuration remains a separate user-selected trust boundary, and `URLSession` can use macOS network/proxy settings. The CLI-specific `CODEX_AC_USAGE_PROXY` setting is documented separately because Codex Balance does not read it directly.

## UI rules

- The menu bar title shows only the 5-hour quota icon and weekly quota icon. A missing 5-hour limit is shown as unlimited instead of reusing the weekly percentage.
- Quota windows are classified by `limit_window_seconds`, so a weekly-only response remains weekly and a future 5-hour window is restored automatically.
- For ChatGPT accounts, the popover shows account alias/email, plan, status, 5-hour quota, weekly quota, Credits, Spark remaining quota, reset countdown, and reset time.
- For API or relay accounts, the popover shows remaining balance or quota, today's cost, total cost, today's tokens, total tokens, and provider/base URL.
- Refresh and usage-page buttons do not close the popover.
- Clicking outside the popover closes it.
- Token consumption totals are shown only for API relay accounts when the relay usage endpoint provides them.
- Membership expiration is intentionally not shown because the current usage endpoint does not expose a reliable field for it.
- The UI follows the first supported macOS preferred language by default.
- The popover language picker supports Automatic/System plus 40 manual languages.
- `CODEX_BALANCE_LANG=<code>` can override the language for one process, which is useful for black-box checks.
- Animation is disabled by default only when no prior preference exists; upgrades preserve the existing animation mask.
- Segment buttons are not shown in the main popover. Right-clicking the quota card opens animation settings with the visibility switch, style picker, and segment selectors 1–5.
- Animation settings stay open during multi-selection and close when clicking outside. Re-enabling animation restores the last non-empty segment selection.

## Refresh behavior

- Automatic refresh interval: 30 seconds.
- Opening the popover triggers an immediate refresh.
- Clicking refresh triggers an immediate refresh.
- Because each refresh rereads `~/.codex/auth.json` and `~/.codex/config.toml`, switching accounts with `ca` is reflected automatically.

## Security boundary

- `last-status.json` can contain account identifiers and quota data; do not attach it publicly without review and redaction.
- A manually edited relay helper is executable local configuration, not passive text.
- The app is distributed ad-hoc signed and is not currently Apple-notarized. The packaged installer recalculates the exact internal file manifest, rejects unlisted files and symbolic links, and verifies the app before and after staging, but the ad-hoc signature does not identify a developer; verify the GitHub release checksum/tag or build from source.
- Network destinations, auth headers, state files, LaunchAgents, packaging, and vulnerability reporting are documented in [Security Policy](../SECURITY.md).
