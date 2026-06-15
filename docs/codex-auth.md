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

## Privacy model

- Auth snapshots remain under `~/.codex-ac`.
- The repository contains only source code and install scripts.
- Registry/cache/status files should not be committed.
