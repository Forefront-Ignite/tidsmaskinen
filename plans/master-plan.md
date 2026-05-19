# Tidsmaskinen — MacBook Activity Tracker for Weekly Time Reports

## Context

You spend the week on a mix of customer meetings, coding for client projects, and ad-hoc research, and at the end of the week you have to reconstruct hours-per-customer-per-day from memory. The goal is a passive macOS menu-bar app that captures the signals that already identify "what customer is this?" — meeting attendees, git remotes, Chrome hosts, Claude Code project paths — and produces a reviewable weekly grid you can paste into your reporting tool.

The repo is greenfield (`/Users/niklas.salarp/Dev/Forefront/Ignite/tidsmaskinen`) so this plan defines the project from scratch.

## Decisions

| Decision | Choice |
|---|---|
| Tech stack | Native macOS menu-bar app, Swift + SwiftUI, SQLite (GRDB) |
| Outlook | Microsoft Graph directly, device-code flow, refresh token in Keychain |
| Tracking depth | App + window title + Chrome URL + git repo path |
| Output | Hours-per-(customer · project)-per-day grid **and** per-day reviewable timeline |
| Attribution | Hybrid — rules table first, Claude API fallback for unmapped blocks |
| Customer model | **Customer → Project hierarchy.** Repos map to customer + project; meetings map to customer only and the user assigns project per-meeting in review |
| Onboarding UX | **Discover-first** — list top observed git repos / hosts / apps by time, assign each to customer (+ project for repos) with one click; auto-creates the rule. Manual rule editor kept as a "Manage" tab |
| Claude Code ingest | Hooks (live) + file watcher on `~/.claude/projects/` (backup) |
| Claude session activity | Sessions are not billed monolithically. Each hook event (SessionStart/UserPromptSubmit/Stop/SessionEnd) extends `activeSeconds`, with idle gaps clamped at `claudeIdleThresholdMinutes` (default 5). A 2h silent stretch contributes only 5 min. Multiple concurrent sessions each track their own activity. |
| Sample interval / idle threshold | Configurable, defaults 15 s / 300 s |
| Idle during meetings | Keep recording (configurable, default on) — listening counts |
| Meeting RSVP filter | Default `acceptedAndTentative`; `acceptedOnly` and `all` selectable |
| Meeting attendance verification | Cross-check against running meeting apps (Zoom/Teams/Webex/Meet); optional badge, never excludes |
| Concurrent meeting + work | **Parallel attribution**: both tracks bill their own customer (configurable) |

## Architecture

```
Tidsmaskinen.app (LSUIElement, menu-bar agent)
├── Capture
│   ├── ActivityMonitor   — NSWorkspace + 15s timer, idle skip via CGEventSource
│   ├── WindowProbe       — Accessibility API → frontmost window title
│   ├── ChromeProbe       — AppleScript → frontmost tab URL/host
│   ├── VSCodeProbe       — Accessibility/AppleScript → workspace path → .git/config remote
│   ├── CalendarSync      — Graph /me/calendarView, 5 min poll w/ delta token
│   └── ClaudeCodeIngest
│       ├── HookReceiver  — Unix socket at ~/.tidsmaskinen/claude.sock
│       └── FileWatcher   — FSEvents on ~/.claude/projects/
├── Storage (SQLite/GRDB)
│   ├── activity_samples  — raw 15s samples
│   ├── activity_blocks   — merged contiguous runs (>30s gap = split)
│   ├── calendar_events
│   ├── claude_sessions
│   ├── customers, projects, rules   — rules optionally target a (customer, project) pair
│   └── attributions      — block_id → (customer_id, project_id?), source (rule|llm|manual)
├── Attribution
│   ├── RuleMatcher       — longest/highest-priority match across signals
│   └── LLMFallback       — Claude API call for unmapped blocks at review time
└── UI
    ├── MenuBarItem       — "Working on: X" + quick-tag override
    ├── Settings          — Graph login, customer rules CRUD, permissions
    └── WeeklyReport      — Grid tab + Timeline tab, TSV export
```

## Critical files to create

```
Package.swift                              # Swift Package; Xcode project optional
Sources/Tidsmaskinen/App.swift             # @main entry, AppDelegate, menu-bar setup
Sources/Tidsmaskinen/Capture/
  ActivityMonitor.swift
  WindowProbe.swift
  ChromeProbe.swift                        # uses NSAppleScript
  VSCodeProbe.swift
  CalendarSync.swift
  ClaudeCodeIngest.swift
Sources/Tidsmaskinen/Graph/
  GraphClient.swift                        # device-code flow + token refresh
  KeychainStore.swift
Sources/Tidsmaskinen/Storage/
  Database.swift                           # GRDB setup, migrations
  Models.swift
Sources/Tidsmaskinen/Attribution/
  RuleMatcher.swift
  LLMFallback.swift                        # Anthropic SDK or URLSession
Sources/Tidsmaskinen/UI/
  MenuBarView.swift
  SettingsView.swift
  WeeklyReportView.swift
  TimelineView.swift
~/.claude/settings.json                    # add hooks pointing at the socket
```

## Key implementation notes

**Sampling.** Default every 15 s (configurable 5–300 s), capture: frontmost app bundle ID, window title, Chrome host (if Chrome frontmost), git repo path (if VS Code/Cursor/Terminal frontmost in a repo). Idle threshold default 300 s (configurable 60–1800 s) via `CGEventSource.secondsSinceLastEventType(.combinedSessionState, anyEventType)`. Idle samples are still recorded but tagged `isIdle=1`; they're excluded from billable totals by default. During an active calendar event (Phase 4+), idle suppression is bypassed if `trackIdleDuringMeetings = true`. Merge contiguous samples with the same `(app, project, host)` into a block; gap > 30 s starts a new block. Block merging is **per source** — switching VS Code projects splits foreground blocks but does not affect a concurrent Claude Code session block in the original project.

**Permissions onboarding.** First launch shows a checklist: Accessibility (TCC `kTCCServiceAccessibility`), Automation for Chrome + VS Code (`kTCCServiceAppleEvents`). Direct user to System Settings panes via `x-apple.systempreferences:` URLs. App is unsigned/dev-id signed locally — document `xattr -d com.apple.quarantine` if needed.

**MS Graph device-code flow.** Use Microsoft's public client ID `14d82eec-204b-4c2f-b7e8-296a70dab67e` (Microsoft Graph PowerShell client) or your own registration. Scopes: `Calendars.Read offline_access User.Read`. Show the user_code in a SwiftUI sheet with a "Copy & Open" button to `https://microsoft.com/devicelogin`. Persist `refresh_token` in Keychain under service `se.forefront.tidsmaskinen`.

**Calendar event filtering.** When syncing `/me/calendarView`, store only events whose `responseStatus.response` matches the configured `MeetingRSVPFilter`. Default `acceptedAndTentative` keeps `accepted` + `tentativelyAccepted`; `acceptedOnly` is stricter; `all` imports declined too (rare; for retroactive review). Declined events are never billed.

**Meeting attendance verification (optional).** When `verifyMeetingAttendance = true`, during each calendar event's time range, check whether any of these bundle IDs were running (via `NSWorkspace.runningApplications` polled at the same 15 s cadence): `us.zoom.xos`, `com.microsoft.teams2`, `com.microsoft.teams`, `Cisco-Webex.Meetings`, `com.hnc.Discord`, `com.tinyspeck.slackmacgap` (huddles), `com.google.Chrome` with a `meet.google.com` URL. If any matched, mark the calendar event `verifiedAttended = 1` and badge it green in the timeline. This never *excludes* events — it only adds confidence.

**Customer / Project / Rule schema.**
```swift
struct Customer  { id: String; name: String; color: String? }
struct Project   { id: String; customerID: String; name: String; color: String? }
struct Rule {
  id: String
  customerID: String
  projectID: String?       // optional — null when the rule maps to a customer at any project
  kind: Kind               // .emailDomain, .gitRemoteHost, .gitRepoSlug, .appBundleID, .claudeProjectPath, .urlHost, .windowTitle
  pattern: String          // glob (gitRepoSlug, urlHost, gitRemoteHost, appBundleID); substring (windowTitle, emailDomain)
  priority: Int            // higher wins, longer pattern as tiebreaker
}
```
Mapping conventions:
- Git repo signals → `(customer, project)` — different repos for the same customer go to different projects.
- URL host / app bundle / window title → typically `(customer, project=null)` unless the host clearly belongs to one project.
- Email domain (meeting attendees) → `(customer, project=null)`. The user chooses a project per-meeting in the review timeline (Phase 6).

**Onboarding via Discover.** Customers window opens to a Discover tab listing top observed signals over the last 7/14/30 days, ranked by time spent (`SignalAggregate(kind, value, totalSeconds)`). Each row shows current attribution or "Unassigned" and an "Assign…" / "Change…" button that opens a sheet with customer + (for repo signals) project picker, with inline "+ New" for both. Save creates a rule with priority 100. Manage tab keeps the manual rule editor as a power-user fallback.

**Claude Code hooks.** Append to `~/.claude/settings.json`:
```jsonc
{
  "hooks": {
    "SessionStart":      [{ "command": "/Applications/Tidsmaskinen.app/Contents/MacOS/tm-hook session_start" }],
    "SessionEnd":        [{ "command": "/Applications/Tidsmaskinen.app/Contents/MacOS/tm-hook session_end" }],
    "UserPromptSubmit":  [{ "command": "/Applications/Tidsmaskinen.app/Contents/MacOS/tm-hook prompt" }]
  }
}
```
`tm-hook` is a tiny Swift CLI bundled in the .app that reads the hook JSON from stdin and POSTs to the local socket. File watcher fills any gaps if the socket is down.

**LLM fallback.** At weekly-report open time, batch all unmapped blocks into one Claude API call (`claude-opus-4-7`) with: existing rules, recent calendar events, the unmapped block summaries. Ask for `{block_id, suggested_customer, confidence, suggested_rule}`. Render as suggestions the user clicks to accept; accepted suggestions persist as new rules.

**Weekly Report UI.**
- **Grid tab**: rows = customers, columns = Mon–Sun, cells = hours rounded to 0.25 h. Footer row totals. "Copy as TSV" → clipboard.
- **Timeline tab**: per day, **multi-track stack** — Calendar | Foreground | Claude Code, top to bottom. Blocks colored by customer; verified meetings get a green dot, RSVP-only get a hollow dot. Hover shows all signals at the cursor's timestamp. Click any block to edit/split/merge/reattribute.
- Concurrent blocks across tracks are simply shown stacked. With `parallelAttribution = on` (default) each track contributes to its own customer total; turning it off forces "primary track wins" for overlap minutes (configurable precedence).
- Unattributed blocks marked with a yellow dot.

## Build phases

1. **Skeleton + capture core** — Package.swift, menu-bar app, SQLite schema, ActivityMonitor + idle detection, debug "raw samples" window. Verifies: app stays alive, samples land in DB.
2. **Probes** — WindowProbe, ChromeProbe, VSCodeProbe, git remote resolution. Verifies: open VS Code in this repo, browse a Chrome tab, see signals in DB.
3. **Customer attribution v1** — rules CRUD UI, RuleMatcher, Weekly Report grid (read-only). Verifies: add a rule for a known repo, hours bucket correctly.
4. **MS Graph** — device-code flow, calendar sync, events appear in timeline with attendee domain. Verifies: real meeting from today shows up with attendees.
5. **Claude Code hooks + file watcher** — `tm-hook` CLI, socket receiver, FSEvents fallback, dedup by session ID. Verifies: starting a Claude Code session in this repo creates a `claude_sessions` row.
6. **LLM fallback + Timeline editing** — Anthropic API call, suggestion UI, manual reattribution, TSV export. Verifies: an unmapped block gets a sensible suggestion you can one-click accept.

## Verification (end-to-end)

1. Build & run: `swift build` then `open .build/debug/Tidsmaskinen.app` (or run from Xcode).
2. Grant Accessibility + Automation when prompted; verify in System Settings → Privacy.
3. Authenticate Graph via Settings → "Sign in to Microsoft"; confirm today's meetings appear in Timeline.
4. Open VS Code in this repo, code for ~2 minutes, switch to Chrome on `acme.com`, then back. Confirm DB has a VS Code block with `repo=tidsmaskinen` and a Chrome block with `host=acme.com`.
5. Run `claude` in another repo; confirm a `claude_sessions` row arrives within ~1 s of `SessionStart`.
6. Open Weekly Report → Grid; confirm totals; click "Copy as TSV"; paste into a spreadsheet.
7. Mark a block unattributed, click "Suggest", confirm Claude proposes a customer + new rule.

## Open items to decide during build (not blockers now)

- Anthropic API key handling: prompt-on-first-use vs read from `ANTHROPIC_API_KEY` env vs keychain entry. Default: keychain entry, settings UI to set it.
- Sleep/wake handling: pause sampling on `NSWorkspace.willSleepNotification`. Trivial.
- Multiple Chrome profiles / Arc / Safari support: scope to Chrome for v1, add others if needed.
