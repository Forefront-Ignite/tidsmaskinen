# Tidsmaskinen

Native macOS menu-bar app that records what you work on (frontmost app, window title, Chrome URL, git repo) and produces a weekly report grouped by `Customer · Project`. Built for personal use at Forefront Ignite to take the friction out of weekly time reports.

## Build & run

Requires macOS 26 (Tahoe) and Swift 6.0+.

```sh
./bin/make-app.sh release
open Tidsmaskinen.app
```

For development iteration:

```sh
swift build
swift run Tidsmaskinen
```

TCC permissions (Accessibility, Automation, Microphone) only persist for the signed `.app` produced by `make-app.sh`. The bare `swift run` binary has no stable bundle identifier, so macOS treats every rebuild as a new app and resets grants.

## What it does

- Samples the frontmost app every 15 s
- Reads Chrome's active tab URL via AppleScript
- Detects which git repo the active editor window belongs to
- Tracks Microsoft Teams calls and microphone activity
- Optional Microsoft Graph calendar sync
- Optional Claude Code and Codex session ingest via shell hooks (`tm-hook`)
- Attributes signals to a `Customer · Project` via user-defined rules
- Outputs a weekly grid you can paste into Forefront's time-report tool

## What it deliberately does NOT do

- No cloud sync — everything is local in `~/Library/Application Support/Tidsmaskinen/db.sqlite`
- No screen recording — just window metadata
- No automatic invoicing — output is TSV / a grid you copy

See [`CLAUDE.md`](./CLAUDE.md) for conventions and [`plans/master-plan.md`](./plans/master-plan.md) for the full design doc.

## Claude Code and Codex activity

In **Settings → Integrations**, use **Install / refresh hooks** under Claude Code or
Codex (OpenAI). Codex hooks are written to `~/.codex/hooks.json` (or
`$CODEX_HOME/hooks.json` when that variable is set for Tidsmaskinen). Existing hooks
are preserved and the original file is backed up as `hooks.json.tm-backup`.

After installing or refreshing Codex hooks, restart Codex and review and trust the
Tidsmaskinen entries using `/hooks` in the Codex CLI. Hooks require a current Codex
client with lifecycle hook support; untrusted hooks are skipped. See the
[official Codex hooks guide](https://learn.chatgpt.com/docs/hooks).

New sessions appear in **Coding Sessions**, the **Coding agents** timeline track,
and weekly reports with their provider and repository attribution. Both providers
use the session idle threshold in Settings. This tracks active time and prompt
counts, not token usage, subscription limits or API spend. Historical Codex sessions
are not imported. Events retain only session ID, cwd and transcript path metadata;
prompts and responses are not copied into the log, and transcripts are not read.

For compatibility with existing installations, both providers use the local
`claude-events.jsonl` log and existing session tables. Existing Claude history and
manual assignments are preserved. Uninstalling a provider's hooks stops future
capture without removing recorded sessions.
