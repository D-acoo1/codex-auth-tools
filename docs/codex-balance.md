# Codex Balance

Codex Balance is a macOS menu bar widget implemented in Swift/AppKit.

## Data flow

For ChatGPT subscription accounts:

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

## UI rules

- The menu bar title shows only the 5-hour quota icon and weekly quota icon with remaining percentages.
- For ChatGPT accounts, the popover shows account alias/email, plan, status, 5-hour quota, weekly quota, Credits, Spark remaining quota, reset countdown, and reset time.
- For API or relay accounts, the popover shows remaining balance or quota, today's cost, total cost, today's tokens, total tokens, and provider/base URL.
- Refresh and usage-page buttons do not close the popover.
- Clicking outside the popover closes it.
- Token consumption totals are shown only for API relay accounts when the relay usage endpoint provides them.
- Membership expiration is intentionally not shown because the current usage endpoint does not expose a reliable field for it.
- The UI follows the first supported macOS preferred language by default.
- The popover language picker supports Automatic/System plus 40 manual languages.
- `CODEX_BALANCE_LANG=<code>` can override the language for one process, which is useful for black-box checks.

## Refresh behavior

- Automatic refresh interval: 30 seconds.
- Opening the popover triggers an immediate refresh.
- Clicking refresh triggers an immediate refresh.
- Because each refresh rereads `~/.codex/auth.json` and `~/.codex/config.toml`, switching accounts with `ca` is reflected automatically.
