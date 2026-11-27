# Tidsmaskinen — MacBook Activity Tracker for Weekly Time Reports

## Current implementation status (reviewed 2026-11-27)

The rest of this document is the original design proposal, not a feature checklist. Use the source and README for current behavior. In particular:

- Capture, rules, timeline, weekly report, Microsoft Graph sync, Command Center sync, and Claude Code/Codex hooks are implemented.
- Hook capture uses an append-only JSONL log and a file watcher/polling ingester. There is no Unix socket receiver or transcript-directory backup scanner.
- Attribution is rule-based or manual. There is no Claude API fallback, suggestion service, timeline split/merge editor, or attendance verifier.
- **Billed time is the user's focus** (focus rework phase 1, below): one timeline where a booked meeting owns its slot and active foreground samples fill the rest, each second once. Claude and Codex samples are attributed through the session that was in front. Agent runtime from hooks is context only and bills nothing. The one exception to "each second once" is a double booking of two accepted meetings the user hasn't resolved yet.
- Idle foreground samples are excluded, even while agents run; calendar duration still counts while idle. The former idle-meeting and attendance toggles had no implementation and have been removed.
- Calendar sync follows all Graph pages before reconciliation. RSVP filtering applies to saved history so changing the filter preserves assignments; cancelled events are excluded from the snapshot.
- Review and Discover coexist in the main window. Customer/project assignment is available for every supported rule kind, not only repository rules.

Original proposals below remain as design history; they are not promises of shipped functionality.

## Focus rework (decided 2026-11-27)

The report used to bill agent runtime: every running Claude/Codex session added hours to its repo's customer, in parallel. A November 2026 replay showed about 338 h credited against about 91 h of the user's own focus on customers. The rework bills where the user's attention is instead. Plan page with the full reasoning and the November replay: https://claude.ai/artifact/VgG73hk3yNXtDArF6xWxdB

Decisions:

- **What bills**: only active foreground samples and booked meetings. Away from the keyboard counts nothing, even while agents run. Agent runtime (hook activity) is shown as context beside each row and never billed.
- **Meetings**: booked time only (the mic overrun goes). A meeting owns its slot; nothing else bills beside it. In an overlap, accepted or organized beats tentative or unanswered. Two of the same standing both bill until the user says which one they were in (Review lists the double booking; `meeting_overlap_choices` stores the answer).
- **Cells calls** (phase 3): count only for the minutes Cells is in front, between the user's own join and leave times; while in a call with Cells in front the 5-minute idle rule pauses. Calls in a project Cell take its Command Center customer; DM and group calls are open Review items.
- **Past weeks**: backfilled only from Claude's own log, which is exact. Nothing is estimated or guessed; Claude time before the log reaches keeps no session.
- **Slack, microphone call detection and window-title rules go** (phase 2). Their stored rows stay in the database unread.

Phases:

1. **Focus billing** (implemented on `feat/focus-timeline`). `AgentFocusRecorder` copies `setFocusedSession` lines from `~/Library/Logs/Claude/main*.log` into `claude_focus_events` as they are written (the log keeps about three weeks) and puts the focused session on each sample (`activity_samples.agentSessionID`; Codex by window title → its `threads` table). `RuleMatcher.attribute(_:)` resolves a sample: manual assignment, then the session's pin, then its repo rules at the sample's time, then the app's own rules. `WeeklyReport`, `ReviewQueue` and My day share `MeetingBilling` and `FocusSpans` (`Attribution/FocusTimeline.swift`). Review gains agent-session rows (pin a session with no git repo) and double-booking rows. Health: a "Claude focus" check.
2. **Remove call detection, Slack and window-title rules** (implemented on `feat/remove-calls-slack`, stacked on phase 1): MicMonitor, the Calls tab, call rows and the report's call source, participant rules, overrun/ownership logic, the call health row and Call UI probe, Slack parsing, and the retired rule kinds. Retired kinds must be skipped when rules load (a leftover row must not break decoding), and the Slack parsers stay for the old migrations that call them.
3. **Cells**: in the Cells repo, allow read-only tokens on recent calls with a date range, return each call's Cell customer/project ids and the user's join/leave times, and mirror `document.title` (with the Cell name) into the native window title. Then a Cells token setting, call sync, attribution through Command Center external ids, focus-only call minutes, and mapping Cells window titles to their Cell.
4. **Attention detail** in My day (insight only): key/scroll/click counts from system event counters, your turn vs agent running (needs the Notification hook added to `tm-hook` and the installer), switches per hour.

## Context

You spend the week on a mix of customer meetings, coding for client projects, and ad-hoc research, and at the end of the week you have to reconstruct hours-per-customer-per-day from memory. The goal is a passive macOS menu-bar app that captures the signals that already identify "what customer is this?" — meeting attendees, git remotes, Chrome hosts, Claude Code project paths — and produces a reviewable weekly grid you can paste into your reporting tool.

The repo is greenfield so this plan defines the project from scratch.

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
  kind: Kind               // .gitRemoteHost, .gitRepoSlug, .appBundleID, .urlHost, .urlPath, .windowTitle
  pattern: String          // glob (gitRepoSlug, urlHost, urlPath, gitRemoteHost, appBundleID); substring (windowTitle)
  priority: Int            // higher wins, longer pattern as tiebreaker
}
```
Mapping conventions:
- Git repo signals → `(customer, project)` — different repos for the same customer go to different projects.
- URL host / app bundle / window title → typically `(customer, project=null)` unless the host clearly belongs to one project.
- **Calendar events are not rule-driven.** Attribution is explicit per series (stored in `meeting_series_attributions`, keyed by Graph's `seriesMasterId`) or per individual event (`CalendarEvent.customerID/projectID`); either can be flagged `isIgnored` to exclude from Timeline and the weekly report. The earlier `.emailDomain` rule kind (attendee-domain auto-match) is removed — see migration `v12_meeting_series_and_ignore`.

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
