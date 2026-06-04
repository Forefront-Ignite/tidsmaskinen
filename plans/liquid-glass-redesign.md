# Tidsmaskinen — Liquid Glass redesign

Source: a Claude Design handoff bundle ("Tidsmaskinen Liquid Glass Edition").
The prototype is an HTML/React mock (`reimagine/styles.css` + `glass.css` + `app.jsx`
+ `data.js`). Per the bundle README the job is to **recreate the design natively** in
the real SwiftUI app — match the visual output, not copy the prototype's structure.

This plan records what was investigated, what is genuinely **new functionality** vs an
**existing feature being restyled**, and a phased path to implement it on macOS 26 (Tahoe)
using native SwiftUI Liquid Glass.

---

## What the design is

A ground-up restyle of the app into Apple's "Liquid Glass" look — a colorful animated
wallpaper behind one frosted floating window, translucent inner surfaces with specular
rims, and a cohesive light/dark/auto theme. The app is reorganized around five views plus
the menu-bar popover:

| Design view | Maps to existing | Nature |
|---|---|---|
| **Report** (weekly report) | `WeeklyReportView` | Restyle + 2 small new metrics |
| **Review** (attribution triage) | `DiscoverView` | New UX paradigm over existing data |
| **My day** (timeline) | `TimelineView` | Restyle, existing functionality |
| **Customers & Rules** | `CustomersView` / `CustomersWindowView` | Restyle |
| **Settings** (two-pane) | `SettingsView` | Restyle (re-group existing settings) |
| **Menu bar + tray popover** | `MenuBarView` | Restyle |

It also introduces a visual identity: a **segmented-clock app mark** (a donut split into
the customer color palette with a clock hand) that renders colorful (app icon), white-on-
indigo (rail), and monochrome (menu-bar tray glyph).

---

## New functionality vs. existing (the core investigation)

### Already exists in the codebase — design only restyles it
- **Rules** of every kind the design uses — `gitRepoSlug`, `gitRemoteHost`, `urlHost`,
  `urlPath`, `windowTitle`, `appBundleID`, `slackChannel` — with priority + glob matching
  (`Models.swift` `Rule.Kind`, `RuleMatcher.swift`).
- **Host/URL path groups** — `urlPath` rules match before `urlHost`; Discover already
  expands a host into its paths; `Database.urlPathAggregates(forHost:)`. The design's
  "assign specific github.com paths, never the root" is already the model.
- **CC (Command Center, read-only) vs LOCAL (editable)** — `Customer/Project.externalSource`
  (`nil` = local, `"command-center"` = synced read-only, `"command-center-archived"`).
  `createLocalCustomer` / `createLocalProject` exist. The CC/LOCAL chips are pure UI.
- **Per-occurrence / per-session attribution** — `MicSession`, `ClaudeSession`,
  `CalendarEvent`, and `ActivitySample` each carry their own `customerID/projectID`. The
  "same colleague Mon vs Tue → different customers" scenario already works
  (`setMicSessionAttribution`). Calls already split into sessions with date+time.
- **Weekly aggregation** — per `(customer, project?)` × day hours, day totals, and a
  **separate `unattributedPerDay`** track (`WeeklyReport.swift`). Cross-source dedup by
  priority (events > claude > samples).
- **Meeting series attribution + ignore** — whole-series rules keyed by `seriesMasterId`,
  per-event override, per-event/series ignore (`meeting_series_attributions`, v12).
- **Inline customer/project creation** in the attribution picker
  (`AttributionPickerSection`).
- **Menu-bar popover** with live "now" status, sync state, quick tiles, footer icons
  (`MenuBarView`).

### New functionality the design implies (not in the app today)
1. **Confidence-scored suggestions with a human reason.** The Review experience centers on
   `"Brightline · Continuous dev — 96% match · Recurring Brightline series"`. The app has
   **no suggestion engine** — only deterministic rule match / no-match (`RuleMatcher`). The
   master-plan's LLM fallback was never built.
   - Scope decision: implement as a **heuristic** suggestion (e.g. near-miss rule matches,
     same-owner repos, attendee/channel overlap, sibling-path rules) returning
     `{customerID, projectID?, confidence, reason}`. LLM fallback can come later. **No
     suggestion is also a valid state** ("No confident match — choose or skip"), already
     shown in the design.
2. **The Review card-stack triage flow itself.** A guided one-at-a-time queue (suggestion →
   Confirm / Choose another / Skip / Ignore), progress meter, ghost stack, ↵/S keyboard
   shortcuts, host-group cards, per-occurrence rows, and an "all caught up" celebration.
   Built entirely on existing data, but it's a new screen, not just a restyle of the
   Discover list. (Discover can remain as the power-user list, or Review supersedes it.)
3. **"Skip for now" (temporary defer)** distinct from **Ignore (never ask again).** Today
   only permanent ignore/hide exist. Skip is session-local in the prototype; decide whether
   to persist (a `skipped_until` / per-week skip set) or keep it in-memory per review pass.
4. **Rule learning on confirm.** Confirming a repo/url/series in Review auto-creates the
   reusable rule ("Always"); single meetings/calls stay case-by-case. Rule infra exists;
   the auto-create-on-confirm wiring is new.
5. **Week-over-week delta** ("+5.2h vs last week") on the Report hero. `WeeklyReport`
   computes a single week — needs a second-week fetch + diff. Small.
6. **Theme setting (Light / Dark / Auto).** App currently follows the system only; the
   design adds an explicit setting persisted across launches and applied before first paint.
7. **Liquid Glass visual system + animated wallpaper + segmented-clock identity.** New
   look across every surface.

---

## Implementation approach (native SwiftUI, macOS 26 Tahoe)

Do **not** port the React/CSS. Rebuild the visuals with native Liquid Glass
(`.glassEffect`, `GlassEffectContainer`, materials) so the app gets real system vibrancy,
not a CSS imitation. The prototype's numbers/colors/spacing are the spec.

### Shared foundation (build first — everything depends on it)
- **Design tokens** — a `Theme`/`DesignSystem` with the palette (`--accent #5b54ff`,
  customer colors `#8b5cf6 #10b981 #f59e0b #6366f1`), radii, typography scale, and the
  light/dark token sets from `styles.css` `:root` / `[data-theme=dark]`.
- **Theme setting** — `SettingsKey.appearance` (`light|dark|system`) + `@AppStorage`,
  applied via the window's `preferredColorScheme`.
- **`AppMark`** — the segmented-clock SVG rebuilt as a SwiftUI `Shape`/`Canvas`, in the
  three renderings (colorful / white-on-indigo / monochrome template for the tray).
- **Glass surface modifiers** — reusable `.glassCard()`, hero card, pill, chip, meter,
  stacked-bar, spark, and stepper styles so each view composes from the same parts.
- **Suggestion engine** — `AttributionSuggester` returning
  `Suggestion?{customerID, projectID?, confidence, reason}` for a signal/session/event,
  heuristic to start. Feeds Review.

### Phase 1 — Report ✅
Restyled `WeeklyReportView`: hero (tracked-this-week + week-over-week delta computed from a
second `WeeklyReport.compute` over the prior week), attribution meter (customer-colored
segments + hatched unattributed), stacked-by-day bar chart, expandable customer rows with
sparkline + share % drilling into project hours, and a dashed unattributed row linking into
Review. Kept "Copy as TSV".

**Deliberate change:** the report is now **read-only** (matches the prototype). In-report
meeting reattribution (the old per-contributor sheet + `WeeklyReportRowDetailView`) is
removed from this view — reattribution lives in Timeline's `ReattributePopover` and the new
Review flow. `WeeklyReportRowDetailView.swift` is now unused (left in tree, candidate for
deletion in Phase 6).

### Phase 2 — Review ✅ (largest new piece)
New `ReviewView` triage screen built on the same unattributed pool Discover surfaced
(reusing `signalAggregates`, `sessionRepoAggregates`, `urlPathAggregates`,
`meetingSeriesAggregates`, `oneOffMeetingAggregates` + the `RuleMatcher`). One-at-a-time
glass card stack with a progress meter and "all caught up" done state. `ReviewUnit` models
single signals, **host groups** (assign each path, never the shared host), meeting series
(whole-series), and one-off events. Manual-pick mode via the shared
`AttributionPickerSection` (no suggestions). Confirm writes a rule for ruleable signals
(priority 100, same as Discover did) or per-series / per-event attribution for meetings;
**Skip** is in-memory (`skipped` set); **Ignore** hides hosts/apps or ignores meetings
(repos are skip-only). `s` skips the current card.

**Discover removed.** `MainWindowView` sidebar item `discover` → `review` (`ReviewView`);
`DiscoverView.swift` deleted. The Report CTA and menu-bar tile now point at `.review`.

### Phase 3 — My day ✅
Renamed the `timeline` sidebar item to **"My day"**. Restructured `TimelineView` into a
vertical scroll: a **day-stats** row (active / sources / tracks), the existing zoomable
Gantt kept intact as a **capped glass overview strip**, and a new **readable agenda** of
glass rows (time range · duration · icon · title · customer tag, or an inline *Attribute*
button when unattributed). Agenda rows open the **same `ReattributePopover`** via a
separate `agendaBlock` binding, so the Gantt strip's own popover never collides and all
existing reattribution / ignore / undo behavior is preserved. The readability complaint
that motivated the redesign is solved by the agenda; the Gantt remains for the at-a-glance
day shape.

### Phase 4 — Customers & Rules ✅
Restyled `CustomersView`: glass detail header with a `SourceChip` (CC read-only note vs
LOCAL + Add rule), projects in a glass card, and **"Learned rules" grouped by kind**
(Repositories / Browser URLs / Apps / Window titles / Slack channels) as glass cards with
`pattern → project` rows + delete — the priority column is gone. Sidebar rows gained the
CC/LOCAL chip. CRUD, the add-rule sheet, and Command Center sync are unchanged. (Meeting-
series attributions aren't `Rule` rows, so they don't appear here — they're managed in
Review / My day, matching the data model.)

### Phase 5 — Settings (two-pane) + Menu bar popover ✅
`SettingsView` rebuilt as a **two-pane** `HSplitView`: a `SettingsCategory` rail (General /
Tracking / Calendar / Integrations / Ignored, each with an icon + one-line detail) driving a
per-category `Form`. All existing controls were regrouped (Appearance + Updates + Startup;
Sampling + Attribution; Meetings + Microsoft account; Command Center + Claude Code), and a
new **Ignored** pane lists hidden hosts/apps (`allHiddenSignals`) with one-click un-ignore
(badge count in the rail). The menu-bar popover header now uses the **`AppMark` badge**.

### Phase 6 — Liquid Glass polish ✅ (with deliberate scope calls)
- **Backdrop:** added a theme-aware `TMWallpaper` (soft peach/sky/violet/mint mesh in
  light, deep tints in dark) behind Report, Review and My day so the native
  `.glassEffect` cards have a colorful surface to refract. Customers/Settings keep the
  system split-view chrome.
- **Dark mode:** carried by semantic colors + materials + `.glassEffect` + the dark branch
  of `TMWallpaper`; the explicit Light/Dark/Auto setting drives it.
- **Cleanup:** deleted the now-dead `DiscoverView.swift`, `WeeklyReportRowDetailView.swift`,
  and `AssignmentSheet.swift`.

**Deliberate non-ports (follow-ups):**
- *Animated* wallpaper blobs — dropped in favor of a calm static mesh; an always-animating
  background is inappropriate for a utility window and costs GPU. Native vibrancy via
  `.glassEffect` is the idiomatic macOS 26 equivalent of the prototype's frosted sheet.
- *Custom app icon / monochrome tray glyph* — `AppMark` is rendered live in-app (rail,
  popover), but generating a real `.icns` from it and a template menu-bar image is left as
  a follow-up; the tray keeps the SF Symbol clock for now.

---

## Scope decisions (confirmed 2026-06)
- **Full redesign, phased** — work through all six phases in order, built to production
  quality on this branch with the intent to merge. `swift build` stays green at each step.
- **No suggestion engine (for now).** Review opens each item in **manual-pick mode** — no
  confidence banner. The suggestion engine is dropped from scope; Review's value is the
  guided one-at-a-time triage + rule learning, not AI suggestions. (`AttributionSuggester`
  is *not* built. The design's `suggestion`/confidence UI is omitted.)
- **Review replaces Discover.** Review becomes the primary attribution surface; the
  Discover sidebar item / view is removed and its data sources feed Review instead.
- **Skip-for-now** = in-memory per review pass (not persisted). **Ignore** keeps the
  existing persistent semantics.
- **Wallpaper**: implement the animated glass wallpaper per the design (Phase 6); revisit
  if it feels heavy for a utility app.

Because suggestions are dropped, Review's cards lead with **"Choose customer"** (manual
picker) instead of a suggestion → Confirm. Confirm/skip/ignore, host-group cards,
per-occurrence rows, progress, and rule-learning-on-confirm all stay.
