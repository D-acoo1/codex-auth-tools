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
ca doctor             # environment checks
```


## API / relay accounts

`ca` can also manage OpenAI-compatible API keys and relay domains. The API key is saved in macOS Keychain when available, or in a private fallback file under `~/.codex-ac/secrets`; it is not written to `config.toml`.

```bash
printf 'sk-...' | ca add-api relay --base-url https://relay.example.com/v1 --model gpt-5-codex
ca s relay
ca current
ca ll --cached --alias
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
