# AI Usage — Mac menu bar widget

A tiny native macOS menu bar app showing **Claude** and **Codex** subscription
usage and limits. The menu bar reads `CL <claude 5h%> · CX <codex 5h%>`; click
for both windows, reset times, and balances per tool.

## How it works

### Claude (network)

- Reads the OAuth access token Claude Code stores in the macOS login Keychain
  (`Claude Code-credentials`) on **every** poll. Because Claude Code keeps that
  token refreshed, this app never runs the OAuth refresh flow itself — as long
  as you use Claude Code, the token stays valid.
- Calls `GET https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.

### Codex (local, no network)

- The Codex CLI records a `rate_limits` snapshot (`primary` = 5-hour,
  `secondary` = 7-day) into its session logs under `~/.codex/sessions/.../*.jsonl`
  on every turn.
- The widget finds the newest session file and reads the last `rate_limits`
  block — no token, no network call. The dropdown shows how old the snapshot is
  (it only updates when you actually use Codex).

Refreshes every 60s (see `pollInterval` in `Sources/ClaudeUsage/main.swift`).

## Build & run

Requires the Swift toolchain (Xcode Command Line Tools is enough; no full Xcode).

```bash
./build.sh
open ClaudeUsage.app
```

On first launch macOS asks to let the app read the `Claude Code-credentials`
Keychain item — click **Always Allow**.

### Install / autostart

```bash
cp -r ClaudeUsage.app /Applications/
```

Then add it under **System Settings → General → Login Items** to launch at login.

## Notes

- Needs an active Claude Code login (Pro/Max). If no token is found it shows
  `⚡ ⚠️` with a hint.
- Endpoint and beta header are undocumented; if Anthropic changes them, update
  `usageURL` / the `anthropic-beta` header in `main.swift`.
```
