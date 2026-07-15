# Codex Auth (`ca`)

Codex Auth is a local Codex account manager. It stores private auth snapshots outside the repository and switches the active Codex account by replacing `~/.codex/auth.json`.

## Important paths

| Path | Purpose |
| --- | --- |
| `~/.codex/auth.json` | Current active Codex auth file. |
| `~/.codex/accounts/registry.json` | Codex account registry when available. |
| `~/.codex-ac` | Codex Auth local account store. |

## Common commands

```bash
ca ll                 # list accounts and usage
ca current            # print current alias
ca import-current fox # save current auth as alias fox
ca s fox              # switch active account
ca r fox              # relogin/update one account snapshot
ca keepalive --dry-run # show which snapshots are due without changing them
ca keepalive           # run one keepalive check now
ca doctor             # environment checks
```

## Automatic keepalive

The installer creates this LaunchAgent:

```text
~/Library/LaunchAgents/com.codexlocaltools.codex-auth-keepalive.plist
```

It runs once when loaded and then every 24 hours. Each run:

- synchronizes the active account snapshot but leaves token renewal to Codex;
- skips API and relay profiles;
- skips inactive ChatGPT snapshots with more than 72 hours remaining;
- renews due snapshots through the installed Codex `app-server` in an isolated temporary `CODEX_HOME`;
- atomically updates the saved snapshot only after the returned account identity and expiry are validated.

If Codex reports that a refresh token is expired, reused, or invalidated, the original snapshot is left untouched and the account is marked as requiring login. Recover it with:

```bash
ca r <alias>
```

Keepalive logs contain statuses only and are stored under `~/Library/Logs/CodexAuth`. To install without loading the scheduled job, use `./scripts/install-codex-auth.sh --no-start`.


## API / relay accounts

`ca` can also manage OpenAI-compatible API keys and relay domains. The API key is saved in macOS Keychain when available, or in a private fallback file under `~/.codex-ac/secrets`; it is not written to `config.toml`.

```bash
printf 'sk-...' | ca add-api relay --base-url https://relay.example.com/v1 --model gpt-5-codex
ca s relay
ca current
ca ll --cached --alias
```

Quota windows are classified by their actual duration. If a usage response has a weekly window but no 5-hour window, `ca ll` shows `∞` for the 5-hour value instead of duplicating the weekly percentage; it automatically returns to percentage display when the 5-hour window reappears. Older installations without a native `~/.codex/accounts` registry refresh from the saved `~/.codex-ac` snapshots directly.

For sub2api-compatible relays, Codex Balance automatically reads `GET <base-url>/usage`. If the relay uses a different endpoint, store it with the profile:

```bash
printf 'sk-...' | ca add-api relay --base-url https://relay.example.com/v1 --usage-url https://relay.example.com/v1/usage --model gpt-5-codex
```

When an API profile is active, `ca` writes a managed `model_provider` block to `~/.codex/config.toml`:

```toml
model_provider = "relay"

[model_providers.relay]
name = "relay"
base_url = "https://relay.example.com/v1"
wire_api = "responses"

[model_providers.relay.auth]
command = "/path/to/private/key-helper.sh"
timeout_ms = 5000
refresh_interval_ms = 300000
```

Switching back to a ChatGPT login removes the managed API provider block and restores the selected `auth.json` snapshot:

```bash
ca s fox --skip-expiry-check
```

Codex Balance detects this API or relay mode and shows it as an API account instead of trying to read ChatGPT subscription quota.

## Privacy model

- Auth snapshots remain under `~/.codex-ac`.
- The repository contains only source code and install scripts.
- Registry/cache/status files should not be committed.
