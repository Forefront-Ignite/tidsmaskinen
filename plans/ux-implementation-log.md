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
