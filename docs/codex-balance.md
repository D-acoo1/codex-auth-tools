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
3. Show API mode in the status bar and popover instead of calling the ChatGPT quota endpoint.
4. Never read or display the API key.

## UI rules

- The menu bar title shows only the 5-hour quota icon and weekly quota icon with remaining percentages.
- For ChatGPT accounts, the popover shows account alias/email, plan, status, 5-hour quota, weekly quota, Credits, Spark remaining quota, reset countdown, and reset time.
- For API or relay accounts, the popover shows API mode and the configured provider/base URL instead of subscription quota.
- Refresh and usage-page buttons do not close the popover.
- Clicking outside the popover closes it.
- Token consumption totals are intentionally not shown because they come from local thread history rather than the server quota API.
- Membership expiration is intentionally not shown because the current usage endpoint does not expose a reliable field for it.

## Refresh behavior

- Automatic refresh interval: 30 seconds.
- Opening the popover triggers an immediate refresh.
- Clicking refresh triggers an immediate refresh.
- Because each refresh rereads `~/.codex/auth.json` and `~/.codex/config.toml`, switching accounts with `ca` is reflected automatically.
