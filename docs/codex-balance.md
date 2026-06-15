# Codex Balance

Codex Balance is a macOS menu bar widget implemented in Swift/AppKit.

## Data flow

1. Read active auth from `~/.codex/auth.json`.
2. Use the `tokens.access_token` as a bearer token.
3. Fetch `https://chatgpt.com/backend-api/wham/usage`.
4. Render quota information in the status bar and popover.
5. Write a local debug/status snapshot to `~/Library/Application Support/CodexBalance/last-status.json`.

## UI rules

- The menu bar title shows only the 5-hour quota icon and weekly quota icon with remaining percentages.
- The popover shows account alias/email, plan, status, 5-hour quota, weekly quota, Credits, Spark remaining quota, reset countdown, and reset time.
- Refresh and usage-page buttons do not close the popover.
- Clicking outside the popover closes it.
- Token consumption totals are intentionally not shown because they come from local thread history rather than the server quota API.
- Membership expiration is intentionally not shown because the current usage endpoint does not expose a reliable field for it.

## Refresh behavior

- Automatic refresh interval: 30 seconds.
- Opening the popover triggers an immediate refresh.
- Clicking refresh triggers an immediate refresh.
- Because each refresh rereads `~/.codex/auth.json`, switching accounts with `ca` is reflected automatically.
