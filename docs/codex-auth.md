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
ca ll --cached        # list cached usage without refreshing saved accounts
ca current            # print current alias
ca import-current fox # save current auth as alias fox
ca s fox              # switch active account
ca r fox              # relogin/update one account snapshot
ca keepalive --dry-run # show which snapshots are due without changing them
ca keepalive           # run one keepalive check now
ca doctor             # environment checks
```

`ca ll` and `ca refresh` can use each saved ChatGPT snapshot's access token to refresh stale quota rows. `ca ll` includes a `RESET` column for the available reset-credit count: an integer (including `0`) means the value was read successfully, `?` means it is unavailable, and `-` means the row is an API/relay profile where it does not apply. The `UPDATED` column is the age of the usage snapshot. If a live refresh fails while a previous snapshot is available, the table keeps showing that snapshot, appends `!` to `UPDATED`, and prints a warning instead of replacing useful values with an error label. `ca ll --cached` does not perform a network refresh and shows the last known reset count without the live-refresh marker. These requests currently target `https://chatgpt.com/backend-api/wham/usage`, an implementation-detail endpoint without a stable public API contract. The endpoint may change and must be re-reviewed if the source changes.

Before `ca s <alias>` replaces the active ChatGPT account, it identity-checks `~/.codex/auth.json` and saves it back to the outgoing account when Codex has rotated that login to a newer credential. A stale live file never overwrites a fresher saved snapshot, and the switch stops instead of discarding a newer credential if that save cannot be completed.

CLI refresh uses `CODEX_AC_USAGE_PROXY`, then `HTTPS_PROXY`, then `https_proxy` when set. Python's networking layer can also honor platform proxy configuration. Check both environment variables and macOS proxy settings when investigating unexpected traffic.

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

The `auth.command` value is executable configuration. Codex Balance invokes the matched helper through `/bin/sh -c` with a 5-second timeout to read the key, so a provider block or registry entry from an untrusted source is equivalent to running an untrusted command as the current user. `ca add-api` generates a narrow helper that reads only the matching Keychain item or private fallback file; review any manually edited helper before activating that profile.

The profile's `usage_url` is also a trust boundary. Codex Balance sends the profile key in both `Authorization: Bearer` and `x-api-key` headers for relay compatibility. Use only a TLS endpoint operated by a party that is allowed to receive that key, and recheck environment and macOS proxy settings before diagnosing unexpected traffic.

## Privacy model

- Auth snapshots are persisted under `~/.codex-ac`; access tokens are sent to the selected ChatGPT service only for authenticated refresh or renewal operations.
- API keys are persisted in macOS Keychain or a mode-`0600` fallback file under `~/.codex-ac/secrets`; the active key is sent to its configured relay when Codex or Codex Balance makes an authenticated request.
- The repository contains only source code and install scripts.
- Registry/cache/status files should not be committed.
- Keepalive status logs must not contain OAuth payloads or complete token values.
- The CLI wrapper and runtime trust `python3`, `codex`, `codex-auth`, `node`, `curl`, `osascript`, and `open` resolved from `PATH`, plus documented fixed macOS tools. Review executable lookup as part of the local trust boundary.

See [Security Policy](../SECURITY.md) for the complete sensitive-file inventory, network destinations, command-execution boundary, and vulnerability reporting path.
