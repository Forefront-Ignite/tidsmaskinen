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
7. The deferred items that needed no model decision

## Deferred items (all stages)

| # | Item | Why deferred | Revisit when |
|---|---|---|---|
| D1 | "This and following" option on recurring-meeting attribution | Needs a validity window on `meeting_series_attributions` (schema migration + `RuleMatcher.attribute(event:)` + every reader) | Stage 3 touches series attribution |
| D2 | Retroactive impact count on Confirm ("also changes 14 items, 9.2 h") | **Done in stage 7** as open time the Always rule also clears in the other weeks of the backlog window; the full re-attribution diff over all history was judged not worth a per-selection re-resolve | — |
| D3 | Popover declares existing rules for the pattern before overwriting | **Done in stage 7** in Review's decision note (Customers flags conflicts since stage 6); the Timeline popover still doesn't | Timeline popover, if it nags |
| D4 | Shared-host guard (localhost / Azure / Microsoft portals → "assign paths instead") | **Done in stage 7** (warn, not block) | — |
| D5 | Live match count while editing a rule ("62 samples in the last 90 days") | **Done in stage 7** (`ruleMatchCount`) | — |
| D6 | Learnable rule kind for Teams/Zoom 1:1 calls (participant-keyed) | **Done in stage 7** (`participant` rule kind, no migration) | — |
| D7 | Manual time entry | Missing concept in the schema; needs a data-model decision first | Stage 6 |
| D8 | Review shows a vertical scroll indicator although the card fits | Gone with list mode (stage 3) | — |
| D9 | Discover's auto-opened customer picker covers the scope control | Moot: Discover deleted (stage 3) | — |
| D10 | Timeline blocks are tap gestures, not buttons: no accessibility action, not keyboard-reachable, not drivable headlessly | **Done in stage 4** (accessibility labels and actions) | — |
| D11 | Tertiary captions ("Attributed on its own — no rule is created", "each cell is that project's hours that day") are low-contrast on the gradient wallpaper | Largely done in stage 6 (`.secondary` captions) | — |
| D12 | Project labels wrap mid-word in the report grid ("Scenarioplane ring - Lumorio") although the column has room | Done in stage 6 (tail truncation) | — |
| D13 | **Deviation from the mock, kept after stage 7:** app-only time is listed in Review (Apps & sites, "Unattributed") but is *not* counted as open, so the report/tray backlog numbers are unchanged. The mock counts apps as open. | `ReviewQueue.build` deliberately excluded apps (an editor or browser can't be pinned to one customer; counting them would nag every week) and the report/tray depend on it | Revisit if the user wants apps in the open count — one line in `ReviewQueue.rows` (`ambientWhenOpen`) |
| D14 | Evidence in the detail pane: the three longest sessions with window titles / paths linking into My day | **Done in stage 7** (`ReviewRow.evidence`, computed in `ReviewQueue.rows` rather than reusing My day's per-day grouping) | — |
| D15 | Delete `SearchableEntityPicker` (`CustomerProjectPicker` covers it; `AddRuleSheet` needs one flag) | Done in stage 6 | — |
| D16 | Host groups as a path checklist with one Confirm (mock) instead of whole-host + per-path Assign rows | Skipped: per-path Assign rows work; a checklist replaces working UI with a visual variant and adds selection state for no new capability | Only if per-path assignment proves too slow in practice |
| D17 | A black horizontal scrollbar thumb is drawn under My day's Gantt card | **Fixed in stage 7**: `.scrollIndicators(.hidden)` still draws the bar on macOS while a mouse is connected; `.never` doesn't | Verify on the signed build with a mouse |
| D18 | Undo toast for the Calls tab's inline Ignore (Review and My day have one) | **Done in stage 7** | — |
| D20 | Menu-bar icon visibility is inferred from the status-bar window being ordered in with a width; macOS 26's "Allow in the Menu Bar" off state was not reproduced, so the check warns rather than fails | Needs a machine with the item disabled to confirm the signal | Stage 6 or when it misfires |
| D21 | Notification on permission loss is verified in code only — needs a real revocation on the signed build to see the prompt and the banner | Dev copy can't lose a grant it never had | First release build test |
| D22 | Customers sidebar section headers ("From Command Center · 22") are low-contrast on the wallpaper; the sidebar scrollbar sits on the split divider | Headers **done in stage 7** (`.secondary`, same header style as the detail sections); the scrollbar position is untouched | Polish pass, needs a look in the view debugger |
| D23 | Week strip (a per-week coloured strip per pattern) instead of the text "week 30, week 35, week 37 only" | Skipped: the stack row already lists the weeks in words; a strip is decoration with no new information | Never, unless a stack grows past what a sentence can hold |
| D24 | Live match count while editing a rule and the shared-host "Assign paths…" affordance in Customers | Duplicate of D5 / D4. The match count is in the Customers editor; the host guard lives in Review, where hosts are assigned | — |
| D19 | Day stats "attributed" can exceed "active" (per-customer sums with quarter-hour rounding vs distinct wall clock, as in the report) — the judge read it as contradictory | Same math as the report by design; **stage 7** adds a tooltip on the stat explaining it (meetings bill their booked length, a call during a meeting bills on top) | — |

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

## Stage 7 — The deferred items that needed no model decision (2026-09-21)

Went through every deferred row and sorted them by the real reason. Only D1 (a validity window
on series attributions) and D7 (manual entry) need a data-model decision; they stay deferred.
D13 stays a deliberate deviation. D16 and D23 are skipped for good: both replace working UI with
a visual variant. D20 and D21 need the signed build.

**Shipped**

- **D6** `participant` rule kind (a string enum case, no migration): `RuleMatcher.attribute(micSession:)`
  matches it after the channel; `MicSession.learnableRule` picks channel, else participant, and the
  Calls sheet, Review's Confirm and the decision note all write whichever it returns. Customers gets
  a "Call participants" group and help text. A recurring Teams/Zoom 1:1 no longer lands in Review
  every week.
- **D5** Live match preview in the Customers rule editor: `AppDatabase.ruleMatchCount` groups the
  last 90 days by the signal column and runs the glob once per distinct value (calls come from mic
  sessions); debounced 300 ms, read off the main thread.
- **D14** `ReviewRow.evidence`: the three longest stretches of consecutive samples on a signal (a gap
  over 2 min starts a new one; open rows list only open stretches) with the title seen most, shown
  as a "Longest stretches" card whose rows open that day in My day.
- **D4** Assigning a whole host warns when it is localhost, a Microsoft/Azure portal, GitHub/GitLab/
  Bitbucket/Atlassian, or already ruled to a customer, pointing at the path rows. Warn, not block.
- **D3** Review's decision note names an existing rule for the same pattern by another customer and
  how the matcher resolves the overlap.
- **D2** For Always, the note says what the rule also clears in the other weeks of the backlog
  window ("Also clears 2.1 h open in 3 other weeks"), resolved off the main thread per selection.
  The full re-attribution diff over all history is not computed: it would need a hypothetical
  matcher re-run over every sample on each picker change for a number that rarely changes a decision.
- **D18** Undo toast (⌘Z, 5 s) for the Calls tab's inline Ignore.
- **D19** Tooltip on My day's "attributed" stat explaining why it can exceed "active".
- **D17** `.scrollIndicators(.never)` on the Gantt: `.hidden` still draws the bar on macOS with a mouse.
- **D22** Customers sidebar section headers use the same `.secondary` header style as the detail sections.
- Table cleanup: D8–D12 and D15 marked done, D24 marked a duplicate of D5/D4.

**Tests:** `CallRuleTests` (participant match, learnable-rule precedence, match count) and an
evidence test in `ReviewRowsTests`. 93 green.

**Independent review (ig-review):** REQUEST CHANGES, all fixed — the impact worker was a detached
task the parent's cancel never reached and ran on every J/K press (now debounced 200 ms, cancellation
forwarded with `withTaskCancellationHandler`, checked between weeks, cancelled on disappear); the
existing-rule note and host warning matched expired day/week rules from months ago (now only
permanent rules or windows overlapping the period on screen); a host that is a plain signal this
week missed its host-group id in other weeks; a dead `.hostGroup` branch in `decisionNote`; per-call
`DateFormatter`s. Not re-reviewed after these mechanical fixes.
**Independent judge (ig-judge):** 8/10, no blocking items, on three captures of the dev copy
(Review with a 1:1 call, the github.com host group with the evidence card and warning, the New rule
sheet with "Matches 39.6 h of activity in the last 90 days"). Its minor note — the day strip printed
"0.046" — is fixed (same `formatHours` as the header: "3 min" / "1.2 h"); its nit about the path
eye icon was already covered by a tooltip and accessibility label the capture can't show. The
judge's proxy rejects more than ~2 MB of PNG, so captures are downscaled to 1200 px; `devdrive`
gained `"<needle>#2"` to reach the second match (a sheet's text field behind the sidebar's).

**Follow-up from the first look at the signed-off build (2026-09-21):** github.com showed 27 min
open with repos that already had rules. They were *git repo* rules, which only cover editor time
with a remote — browsing the same repo on GitHub fell through to the host. The matcher now derives
`owner/repo` from github.com / gitlab.com / bitbucket.org URLs and tries the repo rules before the
host rule (`RuleMatcher.gitSlug(fromForgeURL:)`; the report's contributor label follows). The
evidence card adds "+ 15 min in 9 shorter stretches" so it sums to the header, and a host group's
total is now the host's open time rather than the sum of the paths above the threshold (the
backlog and the report counted only the latter). Note the installed app's review threshold is
10 min, so hosts rarely split into per-path rows there; the dev copy ran on the 5-min default.
Second look: a stretch click landed in My day with nothing pointing at the stretch — the target
now carries the moment and My day selects the block covering it, opening its popover. Hosts split
into per-path assign rows for every open path of a minute or more (the review threshold gates the
host, not its paths), so a single GitHub repo page can get its own rule. Suggestions were "the
customers of the most recently created rules"; now they are earlier answers for the pattern, then
where the host's paths already go, then the customers with the most attributed time in the period,
each tagged with its reason.
Found while verifying the stretch focus: My day dropped *every* sample of a hidden app, sites and
repos included, so with Chrome, VS Code, Slack and Teams hidden as apps the foreground lane held six
blocks for a whole day and the github.com stretch could not be found (the popover landed on the
meeting that overlapped it). `TimelineBuilder.visibleSamples` now applies a hide the way Review
reads it — an app hide covers only app-only time, a host hide covers that site, repo time is never
hidden — so My day, Review and the report agree on what a hide means.

**Copilot review on the PR (8 findings, all confirmed and fixed):** Make permanent deleted the
bounded rules and inserted the permanent one in separate transactions (`replaceRules`, one write);
Review's day strip credited a whole overnight coding session, meeting or call to its start day
(`spread` splits at midnight, delta-backed sessions by their deltas); a series row counted and
spanned occurrences that were individually ignored and already listed on their own; My day's call
blocks only carried a Slack-channel signal, so a 1:1 call could not teach a participant rule from
the popover (`learnableRule` now); the tray report and My day's day stats ignored the rounding
setting; an agent agenda row said "Attribute all N" but pinned only the first session (the popover
now pins every session in the group, in one transaction, and groups by repo slug rather than folder
name); a doc comment had drifted onto `ReportedWeek`.
