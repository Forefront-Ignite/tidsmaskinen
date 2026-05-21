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
- Optional Claude Code session ingest via shell hooks (`tm-hook`)
- Attributes signals to a `Customer · Project` via user-defined rules
- Outputs a weekly grid you can paste into Forefront's time-report tool

## What it deliberately does NOT do

- No cloud sync — everything is local in `~/Library/Application Support/Tidsmaskinen/db.sqlite`
- No screen recording — just window metadata
- No automatic invoicing — output is TSV / a grid you copy

See [`CLAUDE.md`](./CLAUDE.md) for conventions and [`plans/master-plan.md`](./plans/master-plan.md) for the full design doc.
