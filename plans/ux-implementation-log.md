# UX redesign — implementation log

Tracks the staged implementation of `plans/ux-review-2026-09-20.md` on branch
`claude/ui-ux-investigation-redesign-83d09c`. Each stage records what shipped, what the
independent review/judge said, and **what was deferred so it is not lost**. Update this file
at the end of every stage.

Stages (from the review's "Suggested order of work"):

1. Defaults and scope
2. Report errors + report→Review deep link (+ Review card v2)
3. Review list mode; remove Discover and the rolling scope
4. Calls lane, grouped agenda, stable live-block id
5. Tray health + Setup pane + mic permission; Debug → Advanced
6. Report compaction and Customers rule hygiene

## Deferred items (all stages)

| # | Item | Why deferred | Revisit when |
|---|---|---|---|
| D1 | "This and following" option on recurring-meeting attribution | Needs a validity window on `meeting_series_attributions` (schema migration + `RuleMatcher.attribute(event:)` + every reader) | Stage 3 touches series attribution |
| D2 | Retroactive impact count on Confirm ("also changes 14 items, 9.2 h") | Needs a new query over samples/events/calls per candidate rule | Stage 3 (Review list) or later; ship the button without the number first |
| D3 | Popover declares existing rules for the pattern before overwriting | Belongs with the rule-conflict work (write-time flagging) | Stage 6 (Customers rule hygiene) |
| D4 | Shared-host guard (localhost / Azure / Microsoft portals → "assign paths instead") | Belongs with Review list mode and the path checklist | Stage 3 |
| D5 | Live match count while editing a rule ("62 samples in the last 90 days") | Needs a new query | Stage 6 |
| D6 | Learnable rule kind for Teams/Zoom 1:1 calls (participant-keyed) | New rule kind + matcher + Calls sheet; or an honest "not supported" note | Stage 4 (Calls) |
| D7 | Manual time entry | Missing concept in the schema; needs a data-model decision first | Stage 6 |
| D8 | Review shows a vertical scroll indicator although the card fits | Pre-existing; the card ScrollView goes away with list mode | Stage 3 |
| D9 | Discover's auto-opened customer picker covers the scope control | Pre-existing; Discover is deleted | Stage 3 (moot once Discover goes) |
| D10 | Timeline blocks are tap gestures, not buttons: no accessibility action, not keyboard-reachable, not drivable headlessly | Needs `Button`-based blocks; touches the popover anchoring | Stage 4 (Calls lane / agenda rework) |
| D11 | Tertiary captions ("Attributed on its own — no rule is created", "each cell is that project's hours that day") are low-contrast on the gradient wallpaper | Pre-existing style; judge minor in stage 2 | Stage 6 (report compaction) or a global caption pass |
| D12 | Project labels wrap mid-word in the report grid ("Scenarioplane ring - Lumorio") although the column has room | Pre-existing; the grid is rebuilt in stage 6 | Stage 6 |
| D13 | **Deviation from the mock:** app-only time is listed in Review (Apps & sites, "Unattributed") but is *not* counted as open, so the report/tray backlog numbers are unchanged. The mock counts apps as open. | `ReviewQueue.build` deliberately excluded apps (an editor or browser can't be pinned to one customer; counting them would nag every week) and the report/tray depend on it | Revisit if the user wants apps in the open count — one line in `ReviewQueue.rows` (`ambientWhenOpen`) |
| D14 | Evidence in the detail pane: the three longest sessions with window titles / paths linking into My day | Needs sample-level session grouping per signal; the per-day strip and the meeting/call cards are in | Stage 4 (agenda grouping produces the same sessions) |
| D15 | Delete `SearchableEntityPicker` (`CustomerProjectPicker` covers it; `AddRuleSheet` needs one flag) | Still used by the Customers rule editor | Stage 6 |
| D16 | Host groups as a path checklist with one Confirm (mock) instead of whole-host + per-path Assign rows | Functional today; checklist is a UI refinement | After stage 6 if time allows |
| D17 | A black horizontal scrollbar thumb is drawn under My day's Gantt card | Pre-existing; the inner horizontal ScrollView already hides its indicators, so the thumb comes from elsewhere — needs a look with the view debugger | Stage 6 polish |
| D18 | Undo toast for the Calls tab's inline Ignore (Review and My day have one) | Reversible today via the call sheet or Review's Ignored filter | Stage 6 polish |
| D20 | Menu-bar icon visibility is inferred from the status-bar window being ordered in with a width; macOS 26's "Allow in the Menu Bar" off state was not reproduced, so the check warns rather than fails | Needs a machine with the item disabled to confirm the signal | Stage 6 or when it misfires |
| D21 | Notification on permission loss is verified in code only — needs a real revocation on the signed build to see the prompt and the banner | Dev copy can't lose a grant it never had | First release build test |
| D22 | Customers sidebar section headers ("From Command Center · 22") are low-contrast on the wallpaper; the sidebar scrollbar sits on the split divider | Judge nits in stage 6 | Polish pass |
| D23 | Week strip (a per-week coloured strip per pattern) instead of the text "week 30, week 35, week 37 only" | The stack row already lists the weeks; the strip is a visual refinement | Polish pass |
| D24 | Live match count while editing a rule ("62 samples in the last 90 days") and the shared-host "Assign paths…" affordance in Customers | Both need new queries (same as D5 / D4) | With D5 / D4 |
| D19 | Day stats "attributed" can exceed "active" (per-customer sums with quarter-hour rounding vs distinct wall clock, as in the report) — the judge read it as contradictory | Same math as the report by design; a caption could explain it | Stage 6 (report compaction touches the same numbers) |

## Stage 1 — Defaults and scope (2026-09-21)

**Shipped**

- `AttributionScope` cases reordered broad → specific (Always · This week · This day · Just this);
  Timeline popover and Calls sheet use `allCases`, Discover's signal sheet uses the fixed order,
  Review's private `AttrScope` deleted.
- Timeline popover and Calls sheet default to **Always**. On a recurring meeting **Apply to series**
  is the default button and takes Return; Save for this meeting is secondary; Return is inert
  until a customer is picked.
- Review: scope resets to Always on every cursor move and reload; the button prints it
  ("Confirm · This week", "Assign host · Always"); options are Always · This week (· This day
  with a day chip) (· Just this for calls, which can now be pinned without teaching a rule).
- Review Clear deletes exactly the rule that Confirm wrote (tracked in-session), so permanent
  rules and other weeks' assignments for the same pattern survive.

**Tooling added for the per-stage review loop:** `bin/dev-instance.sh` runs an ad-hoc-signed
copy (`se.forefront.tidsmaskinen.dev`) on a `sqlite3 .backup` snapshot with its own data folder
(`TIDSMASKINEN_DATA_DIR` via `AppPaths`) and keychain namespace; `bin/devdrive.swift` navigates it
through Accessibility and `screencapture -l` captures its windows. See CLAUDE.md → "A dev instance
beside the installed app".

**Independent review (ig-review):** stage diff APPROVE, no findings. The dev-instance tooling got
REQUEST CHANGES with four findings, all confirmed and fixed: Diagnostics' `tccutil reset` hardcoded
the live bundle id; the script's `pkill` did not wait before replacing the bundle and snapshot; a dev
copy opened without the env var fell back to the live data folder and keychain namespace (now keyed
on the bundle id too).

**Independent judge (ig-judge):** 8/10, no blocking items, trend 7 → 7 → 8 → 8 → 8. Minor notes were
all pre-existing: Review's scroll indicator when the card fits (D8), Discover's auto-opened picker
covering the scope control (D9), and inactive traffic lights in a background capture (not an issue).
The recurring-meeting popover could not be captured because timeline blocks are tap gestures without
an accessibility action (D10); its series-first default is verified in code only.

**Deferred from this stage:** D1, D2, D3, D4, D8, D9, D10.

## Stage 2 — Silent failures (2026-09-21)

**Shipped**

- Weekly report: a failed load renders "Couldn't load the report" with the error and a Retry
  instead of an endless spinner; a failed refresh over an already-shown report adds the same
  banner above the stale numbers.
- The report's two Review buttons (hero card and "Uncategorized" row) pass the week on screen via
  `reviewTargetWeekStart`, so Review lands on that week — verified in the dev copy (report at
  7–13 Sep → Review at 7–13 Sep).
- Next-week is disabled on the current (or any future) week in the report and in Review.

**Independent review (ig-review):** APPROVE, no findings.
**Independent judge (ig-judge):** 8/10, no blocking items. Applied its nit (`>=` instead of `==`
for the next-week guard). Its two minor notes are pre-existing styling → D11, D12.
The error banner is verified in code only — it needs a database fault to render.

**Deferred from this stage:** D11, D12. Review card v2 (evidence, suggestions, keyboard) is folded
into stage 3's detail pane.

## Stage 3 — Review as list + detail; Discover removed (2026-09-21)

**Shipped**

- `ReviewQueue.rows` classifies every item of the period — open, attributed (with the scope the
  rule was written with: Always / This week / This day / Manual / Series / Pinned / Mixed), ignored,
  or ambient (app-only) — resolved per sample at its own timestamp, with an open-only per-day split
  for open rows. Meetings use mic-extended bounds like the report. `build` is now the open rows, so
  the report and tray backlog are unchanged (test: `ReviewRowsTests`).
- `ReviewView` rewritten: Open / All / Ignored filter, customer filter, search, "Show N under 5 min"
  toggle, list grouped into Git repos / Meetings / Calls / Apps & sites with status chips, a
  permanent detail pane (kind, title, hours, per-day strip, evidence card, suggestions 1–3 with
  earlier answers first, picker, scope, a note on exactly what Confirm writes, Skip H / Ignore E /
  Confirm ↵ with keycaps, contextual legend). Confirm is bordered and inert until a target is
  picked. Attributed rows change in place; ignored rows Restore. Series rows accept This week /
  This day (per-occurrence overrides). Reload after every write, selection kept by id, undo stack
  (⌘Z) that deletes exactly the written rule. Single-key grammar via a local key monitor that
  defers whenever a text field is being edited.
- `DiscoverView` and `AssignmentSheet` deleted; sidebar group "Sources" → "Attribution".
- Verified in the dev copy through accessibility: suggestion → Confirm moved 11 → 10 open and
  advanced the selection; Undo restored 11 and reselected the item; Skip advanced; Ignore → 10 and
  its Undo → 11.

**Independent review (ig-review):** three passes. Pass 1 (REQUEST CHANGES): ⌘Z/⌘←/⌘→ live while
typing in search, meetings not mic-extended, series rows counting individually-ignored occurrences
(and a duplicate ignored row), single-day periods getting a 2-slot day strip — all fixed. Pass 2:
single-key shortcuts vs text fields and `?` needing shift — replaced the SwiftUI shortcut buttons
with an NSEvent monitor gated on the first responder; selection dropping to nothing in All — fixed;
open rows' day strip counting attributed time — fixed; scope lingering on This day — fixed. Pass 3:
the same open-only split for series rows, clipping of individually-ignored occurrences, deinit
off-main guard — fixed. Not re-reviewed after pass 3's mechanical fixes.

**Independent judge (ig-judge):** 6/10 on the first build (blocker: legend said "E ignore" under a
Restore button; majors: disabled Confirm contrast, detail card floating in a void) → 8/10 after the
fixes, no blocking items. Remaining minors applied: keycaps, "Whole week" chip, legible inactive
days, scrollbar inset; header density noted but kept (four rows: navigator, filters, day chips,
progress).

**Deferred from this stage:** D2, D4, D13 (deviation), D14, D15, D16.

## Stage 4 — My day: calls lane, grouped agenda, stable live block (2026-09-21)

**Shipped**

- `TimelineBlock.Track.calls`: each mic session's ad-hoc ranges (mic minus the meetings it *is*, the
  Calls tab's own helper) become blocks with the mic-session attribution and a `slackChannel` rule
  signal; the popover saves them to the session. Ignored calls follow the reveal toggle.
- Work in ignored repos is kept on both tracks and drawn dimmed (`isIgnored`) instead of vanishing;
  ignored meetings and calls share the flag. Test updated (`testTimelineKeepsIgnoredRepoBlocksFlagged`).
- The in-progress foreground block keeps a stable id (first sample only), so its popover survives
  new samples.
- Day stats: active / attributed / open · N items / in meetings — `WeeklyReport.compute` over the
  day and `ReviewQueue.build`, so they agree with the report and Review.
- Agenda grouped by repo, host, app, meeting or call: one row per group with times and total,
  group-wide attribution state ("3 of 17 unattributed"), "Attribute all N" (a synthesized block over
  every sample for foreground groups), "Ignore app" for app-only time, "Ignored repo" tags.
- A Lanes menu (every lane on by default, persisted as `timelineHiddenLanes`) with the hidden/ignored
  reveal replaces the two unlabelled icon toggles; ⌘← ⌘→ ⌘T on the day navigator.
- Timeline blocks and agenda rows carry accessibility labels and actions — VoiceOver and the dev
  driver can open the popover (D10 done). That is how the popover was captured for the judge.
- The block popover is anchored with `.position` instead of `.offset`: `.offset` never moved the
  layout frame, so every popover opened at the row's origin — a pre-existing bug the judge caught.
- Calls tab: All / Unattributed filter with an empty state, inline Attribute / Ignore, no chevron.

**Independent review (ig-review):** pass 1 REQUEST CHANGES — day stat read the wrong report index
(now `grandTotal` of the day), ignored calls missing from the reveal gate, group state read from the
first block only, override flag, Calls empty state — all fixed; ⌘←/⌘→ vs text editing noted but kept
(My day's window has no text fields; the picker's live in popovers). Pass 2 COMMENT — reveal gate
counted ignored repos, fixed.
**Independent judge (ig-judge):** 5/10 (blocker: the popover anchoring bug) → 8/10 after the fixes,
no blocking items. Remaining minors → D17, D18; the pickers' crowding was spaced out.

**Deferred from this stage:** D14 (evidence sessions — the agenda groups now compute them), D17,
D18, D19.

## Stage 5 — Capture health: tray, Setup pane, Debug → Advanced (2026-09-21)

**Shipped**

- `CaptureHealth`: seven checks probed functionally every minute, on activation, on sign-in /
  sign-out / every calendar sync and whenever the tray or Setup opens — `AXIsProcessTrusted`, a
  real `AEDeterminePermissionToAutomateTarget` with `prompt: false` (catching −1743/−1744),
  CoreAudio call detection running (no microphone permission is needed; the check says so),
  Microsoft sign-in plus sync age against a user threshold (default 2 days), hook install state
  plus the events log's mtime, the status-bar window being ordered in (warn only), and customers.
  One notification when Accessibility or Chrome automation flips from working to failed.
- Tray: week line with this week's hours and open hours, "Capturing / Partly capturing", banners
  with a fix for failed checks (plus a stale calendar and missing customers), `state.lastError`,
  a Now card (the current foreground stretch, where it lands, Attribute / Not this?), a two-row
  health stripe, and Review · N / Report / My day. "· N samples" and the meter card are gone.
- Settings: a Setup pane first in the rail (7 live rows, one action each — Grant…, Request access,
  Sign in, Sync now, Set up, Open System Settings with a plain fallback — and the staleness
  threshold) that is the landing pane while anything is not green and stays afterwards; an
  Advanced pane hosting the Debug hub (removed from the sidebar); the static Attribution text in
  Tracking removed. A dot on the tray icon while a source is failing.

**Independent review (ig-review):** three passes. Pass 1: this week's open hours excluded units
seen in earlier weeks, no re-probe after sign-in restore, the Now card walked across gaps, strong
captures — fixed. Pass 2: an explicit Settings target lost to the Setup fallback, a stale Now card,
the occlusion-based menu-bar check misfiring in full-screen/lock (now ordered-in + width, warn),
"signed out" during identity restore — fixed. Pass 3: two action guards — fixed.
**Independent judge (ig-judge):** 6/10 (truncated week line, rail subtitle, Advanced header) →
8/10 after fixes; its last three notes (embedded picker alignment, Now card redundancy, customers
missing from the stripe → tray banner) are applied.

**Deferred from this stage:** D20, D21. The mic check verifies call detection rather than an
AVFoundation permission because detection reads the CoreAudio process list, which needs none.

## Stage 6 — Report compaction, rounding, Customers rule hygiene (2026-09-21)

**Shipped**

- `ReportRounding` (nearest / up / down quarter hour, setting `reportRounding`) in
  `WeeklyReport.compute`; every day keeps its true total — a positive residue goes to the day's
  largest bucket, a negative one comes off the largest buckets that still have time — with
  deterministic tie-breaking and raw cells kept for hover (`ReportRoundingTests`).
- `reported_weeks` (migration v23): "Mark reported" remembers the filed total; the hero flags when
  the current total differs.
- Report view: "Week N" with "through today" on the running week; rounding picker; Mark reported;
  "Copy for Forefront" (⇧⌘C; TSV header now "Customer · Project" with the year); ⌘← ⌘→; a
  stale/signed-out calendar banner from `CaptureHealth`; two hero cards (tracked with the keyboard /
  parallel split and a like-for-like "same point last week"; attributed share with open hours and
  "Review week N"); one grid with collapsible customer rows (retired projects keep their names),
  per-day open chips that open Review on that day, cells that open My day on that day, contributor
  hover, and Attributed / Unattributed → Review / Tracked rows whose totals are the sums of their
  cells. The day bars and the customer list with sparklines are gone.
- Customers: sidebar sections by source instead of a chip per row; rules as stacks per pattern
  described in words ("always · most specific wins", "week 22 only", "always · overridden in week
  23", "expires Sun"); Make permanent with a preview of what it replaces; patterns also claimed by
  another customer flagged (keyed by kind + pattern); Edit in place through the same sheet, which
  saves via `upsertReplacingWindow`; the priority stepper is gone; `SearchableEntityPicker` deleted.

**Independent review (ig-review):** pass 1 — a day target lost when Review changed week, collapsed
customers re-expanding every tick, duplicate rules from the sheet, grid totals not matching their
cells, conflicts keyed by pattern only — fixed. Pass 2 — the day target now applied directly (the
week change keeps a day inside the new week), negative rounding residue distributed across buckets
(test extended), deterministic tie-breaking, archived-inclusive lookups — fixed; not re-reviewed
after these mechanical changes.
**Independent judge (ig-judge):** 6/10 (blocker: three "No project" rows for retired projects;
"always · week 23 only" wording; 1-decimal hero vs quarter-hour grid) → 7/10 after fixes (major:
hero open hours from the week-wide backlog vs the grid's per-day sum — now the same figure; minor:
bare project count — now "N projects"). Sidebar header contrast → D22.

**Deferred from this stage:** D4, D5, D7 (manual entry — still a data-model decision), D11 (largely
addressed by the new captions using `.secondary`), D12 (the grid now truncates project names with
a tail), D15 done, D22, D23, D24.
