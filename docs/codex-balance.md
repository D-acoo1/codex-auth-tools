# Codex Balance

Codex Balance is a macOS menu bar widget implemented in Swift/AppKit.

## Data flow

For ChatGPT subscription accounts, Codex Balance reads only the active account:

1. Read the active auth from `~/.codex/auth.json`.
2. Use `tokens.access_token` as a bearer token and `tokens.account_id` as the `ChatGPT-Account-Id` request header when present. The account header selects the quota context used by the Codex app.
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

- For ChatGPT accounts, the menu bar shows the weekly quota icon/value, task lights, and TPS. The 5-hour timer, value, and quota separator are intentionally hidden; the popover and CLI retain 5-hour information.
- Quota windows are classified by `limit_window_seconds`, so a weekly-only response remains weekly and a future 5-hour window is restored automatically in the popover without changing the compact menu bar. A missing 5-hour limit is shown as unlimited there, never copied from the weekly percentage.
- For ChatGPT accounts, the popover shows account alias/email, plan, status, 5-hour quota, weekly quota, Credits, Spark remaining quota, reset countdown, and reset time.
- Clicking the reset-credit count opens a centered bubble with up to five rows. Each row shows only the expiration in the Mac's current time zone as `M.d HH:mm`; clicking elsewhere dismisses the bubble.
- For API or relay accounts, the popover shows remaining balance or quota, today's cost, total cost, today's tokens, total tokens, and provider/base URL.
- Refresh and usage-page buttons do not close the popover.
- Clicking outside the popover closes it.
- Quota/service-side token consumption totals are shown only for API relay accounts when the relay usage endpoint provides them; the local activity section is separate response metadata, not billing totals.
- Membership expiration is intentionally not shown because the current usage endpoint does not expose a reliable field for it.
- The UI follows the first supported macOS preferred language by default.
- The popover language picker supports Automatic/System plus 40 manual languages.
- `CODEX_BALANCE_LANG=<code>` can override the language for one process, which is useful for black-box checks.
- Animation is disabled by default only when no prior preference exists; upgrades preserve the existing animation mask.
- Segment buttons are not shown in the main popover. Right-clicking the quota card opens animation settings with the visibility switch, style picker, and segment selectors 1–5.
- Animation settings stay open during multi-selection and close when clicking outside. Re-enabling animation restores the last non-empty segment selection.

## Task traffic lights

The three-lamp indicator appended to the menu-bar title is an attention model for local Codex tasks. It is independent of quota state:

| State | Automatic rule |
| --- | --- |
| Red / unread | A user-visible, non-archived thread is present in Codex's unread set and its database `updated_at` is no more than 24 hours old. Subagent threads and rows with agent metadata are excluded from this unread signal. |
| Yellow / running | A non-archived thread has a rollout file modified within the last 75 seconds, and its observed lifecycle still describes an open turn rather than completion, interruption, failure, or an assistant/agent final answer. |
| Green / idle | Neither unread nor running is true. |

Red and yellow are separate booleans and may be active together; green is active only when both are false. A shared background collector discovers tasks and checks freshness every two seconds, independently of the 30-second quota refresh. Known rollout appends are coalesced for 150 ms and update activity without waiting for discovery.

Automatic detection reads local Codex state only:

- unread thread IDs from `$CODEX_HOME/.codex-global-state.json`;
- up to the 250 most recently updated non-archived rows from `$CODEX_HOME/state_5.sqlite`, queried in-process through system SQLite in read-only mode;
- live Codex writer paths from in-process macOS process/open-file metadata; a bounded 256 KiB rollout tail on attachment, then only appended bytes. Silent live writers are attached even at startup; completed inactive readers are released after the activity window.

The default `CODEX_HOME` is `~/.codex`. Reading the lights does not modify Codex's database, rollout files, unread set, or task state, and it does not make a network request.

For deterministic integration checks, `~/Library/Application Support/CodexBalance/task-status.json` can override automatic detection with JSON such as `{"state":"unread+running","override":true}`. Accepted state words include `idle`/`green`, `unread`/`red`, and `running`/`yellow`. `CODEX_BALANCE_STATE_DIR` relocates that file, `CODEX_BALANCE_TASK_LIGHT_MODE=manual` also accepts a plain-text state, and `CodexBalance --task-light-once` prints the resolved state without opening the UI.

## Local model activity

The menu bar adds only a whole number and uppercase unit, such as **`86 TPS`**, next to the existing quota and task lights. It uses a single existing status item, not a second icon. The collector computes the all-model mean from the combined response output and generation-time totals; it never averages already-averaged model speeds. An unmeasured model is not treated as zero. The number uses a bold purple accent with a smaller, quieter TPS unit. A single space separates it from the task lights; the common one-to-three-digit range reserves equal width after the readout rather than leaving a changing gap before the number, so adjacent menu items do not shift. Click the menu bar item to see per-model readings. Hovering over the item does not open a tooltip.

Activity updates refresh the readout even if quotas and lights are unchanged; unchanged rounded values do not rebuild its title. Quota errors remain visible in the popover while the independent local TPS continues updating. `— TPS` is unknown, including an expired/no-sample state. Recent completed samples remain eligible until expiry, but do not imply a running task. The existing subscription and API/relay status formats, task lights, click-to-open behavior, and popover remain intact. No additional timer, helper, request, hook or persisted telemetry is introduced.

The popover groups observed Codex App/CLI activity in the current `CODEX_HOME` by model, including subagents. Each model's primary readout uses an explicit TPS unit, such as **`≈ 86 TPS`**; the input-token amount is secondary. TPS means output tokens per second. Two rows fit in the fixed-height area; additional models scroll rather than being omitted. Value updates reuse the existing rows and preserve the quota card, optional animation, reset-credit bubble, and footer controls.

| Display | Meaning |
| --- | --- |
| Task count / generating / tools / quiet | Open local turns whose rollout is held by a live Codex process, classified from lifecycle/tool metadata. Parent chats and subagents are counted separately. A silent held turn stays counted; a completed loaded chat or orphan log does not. When process inspection is unavailable, log-only activity becomes quiet/unknown after 75 seconds. This is activity detection, not proof of an open model stream. |
| Input `tok` | Sum of each open task's latest response input-token count settled within the last 60 seconds, including its cached subset. It is **not** input TPS, prefill speed, a live upload counter, or account billing usage. |
| `≈ 86 TPS` | Duration-weighted mean across valid responses settled in the last 60 seconds: `sum(output_tokens) / sum(model-generation seconds)`. For each response, model seconds are the union of `event_msg.item_completed.started_at_ms/completed_at_ms` intervals for Reasoning, AgentMessage and Plan. Tool execution is excluded; output already includes reasoning and is never added again. Concurrent responses are averaged, not summed. TPS is rounded to a whole number for display. |
| Input `[measured/tasks]` | Only this many currently open tasks have a recent input count. This marker is not applied to the average TPS because recent completed responses can also contribute. |
| Popover TPS tooltip | Number of valid responses and distinct contributing sessions, including recently completed ones. This describes the observed sample, not complete coverage of every active task. |
| `— TPS` | No valid output sample in the window, missing/zero timing, incomplete initial attachment, skipped oversized/malformed records, or unsupported log shape. No guessed rate or fake zero is substituted. |
| Recent average · idle | No observed open task for this model, but a recent average is retained. It is dimmed and does not turn on the running task light. After the last sample expires, the idle row is removed. |

Codex settles counts after a response rather than continuously emitting authoritative per-token counts to rollouts. This is a **response-sampled, approximate average**, not instantaneous wire/decode speed, total concurrent throughput, or a cross-model benchmark. The window selects whole responses by their settlement timestamps, not individual tokens generated within each wall-clock second. A short 1000 TPS response lasting 0.1s and a 100 TPS response lasting 10s therefore average `1100 / 10.1 ≈ 109 TPS`, not 550 TPS. Item timings can cover only the observable portion of generation; transport latency, invisible model work and tool-call serialization are not reliably measurable here. A generation can be active while no valid rate is available.

Valid samples survive turn boundaries, tool waits and completion for up to 60 seconds and stay attached to the model that produced them. Per-session history is bounded to the latest 128 valid responses within that window; very high response frequency can shorten the effective sample. Every observed Reasoning, AgentMessage and Plan item in a response must have valid start/end timing: one missing or invalid interval excludes the **whole response**, not just that item. Invalid samples do not erase the remaining valid history. Expired history is pruned in memory. Nothing is persisted or re-read to build the mean.

Within a turn, valid native `token_usage_record` records are authoritative and deduplicated by response ID. After one is observed, legacy `event_msg.token_count` mirrors are ignored even if their cumulative totals differ or they arrive late. Legacy-only turns remain supported, using their own cumulative counters for deduplication. If a turn switches from already used legacy accounting to native accounting, pending timing and the first potentially partial native interval are excluded until a clean native accounting boundary is available; earlier valid averages remain visible. Unusable accounting also invalidates the pending boundary instead of assigning its timing to a later response.

The collector also reads macOS process/file-descriptor metadata in-process and matches each rollout path to a running Codex executable. A held rollout with an open turn remains counted across long silent generations/tool waits, including initial attachment after Balance restarts. Loaded but completed chats do not count, and unowned unfinished logs cannot claim a running task. Late item/accounting records do not reopen a completed turn. Parent-chat and subagent counts are shown separately when children contribute. When process inspection is unavailable, the existing log-only 75-second freshness rule remains: silent open turns are quiet/unknown, not proven running or finished. Only the 250 most recently updated, non-archived threads in this Codex home are candidates. Separate homes, remote machines, and other AI apps are not monitored. Unavailable database discovery is explicitly marked; already observed file activity can continue without inventing new tasks. The quota/account collector remains independent.

Implementation uses a single utility-priority serial queue, read-only system SQLite, macOS process/open-file metadata, native file-change notifications, metadata-only decoding, bounded line buffers, and bounded append batches. A valid usage settlement can establish an otherwise unknown open turn when initial attachment skips an oversized tool result; it cannot reopen an observed completion or invent missing TPS timings. The tail stays limited to 256 KiB. The collector never scans the full session directory, launches a helper process for telemetry, subscribes to full desktop conversation snapshots, installs hooks, calls a model, writes Codex state, or persists/sends activity data. The model panel is updated only while open; closed-panel sampling continues for the task lights.

Read-only diagnostic (the executable is inside the installed app bundle):

```bash
"$HOME/Library/Application Support/CodexBalance/CodexBalance.app/Contents/MacOS/CodexBalance" --model-activity-once
```

The standalone diagnostic attaches afresh, so its first response may not yet have enough timing context for a rate. Its JSON identifies the 60-second window and duration-weighted method, with valid-response counts and `overall_tps` (the all-model mean, or null); `measured_tasks` counts contributing sessions (which may include completed tasks). It includes only model names, counts, and measurements; no thread IDs, paths, conversation text, or credentials.

### Open-source references

The implementation is original and adds no package dependencies. Measurement and collection decisions were informed by [codex-pacer](https://github.com/RyanZhangNTU/codex-pacer/tree/785b1c07cadb92e1991901b8ba9f2213d857fcdb) (MIT; response accounting, freshness and bounded incremental collection), [codex-statusbar](https://github.com/dongyue-19/codex-statusbar) (MIT; model-item time unions), and [token-pulse](https://github.com/zzccchen/token-pulse) (MIT; output-only measurements and incomplete-timing handling). Their different metrics are not treated as interchangeable. Full desktop IPC snapshots were evaluated but are unnecessary for this log-based sampler.

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
