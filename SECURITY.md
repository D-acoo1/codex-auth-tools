# Security

This project works with local Codex authentication files. Treat the following as secrets or sensitive local state:

- `~/.codex/auth.json`
- `~/.codex/accounts/*.auth.json`
- `~/.codex-ac/**`
- `~/Library/Application Support/CodexBalance/last-status.json`

Before publishing changes, run:

```bash
rg -n "access_token|id_token|refresh_token|Authorization: Bearer|sk-[A-Za-z0-9]" .
```

Do not include real accounts, auth snapshots, cookies, or tokens in issues, pull requests, or logs.
