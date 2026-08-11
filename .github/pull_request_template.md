## Problem

Describe the user-visible problem and the verified root cause.

## Change

Describe the smallest behavior change made by this pull request.

## Verification

- [ ] `swift build --package-path codex-balance` (required for Swift changes)
- [ ] `python3 tests/keepalive-auth.py` (required for keepalive/auth changes)
- [ ] `bash tests/blackbox-ca-balance.sh` (required for CLI/usage integration changes)
- [ ] `git diff --check`
- [ ] Visible UI changes include a screenshot with synthetic account data
- [ ] Documentation matches the implemented behavior

Paste the relevant command results or explain why a check is not applicable.

## Security and privacy

- [ ] No real auth snapshot, token, cookie, API key, account identifier, private endpoint, local log, or personal screenshot is included
- [ ] Changes to credentials, commands, network destinations, files, LaunchAgents, Keychain, dependencies, signing, quarantine, or packaging are explicitly described
- [ ] Untrusted issue/PR text cannot gain secret, shell, merge, release, or deployment authority
- [ ] Release artifacts are not automatically published from an unreviewed fork or pull request

## Compatibility and rollback

State the tested macOS version, compatibility impact, and rollback path.
