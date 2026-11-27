# Tidsmaskinen

Native macOS menu-bar app that records what the user works on (frontmost app, window title, Chrome URL, git repo) and produces a weekly report grouped by `Customer · Project`. Designed for personal use to make Forefront's weekly time reports easier.

The full design lives in **`plans/master-plan.md`**. Read it before making non-trivial changes.

## Build & run

For development iteration:

```sh
swift build
swift run Tidsmaskinen
```

For real use (required for TCC permissions to stick):

```sh
./bin/make-app.sh release
open Tidsmaskinen.app
```

`swift run` produces a bare executable with **no CFBundleIdentifier** — macOS's TCC system silently refuses to issue Automation prompts and Accessibility grants reset across rebuilds. `bin/make-app.sh` wraps the binary in `Tidsmaskinen.app` with:

- stable bundle ID `se.forefront.tidsmaskinen`
- `LSUIElement` (menu-bar agent, no dock)
- `NSAppleEventsUsageDescription` (the prompt copy users see)
- code signature using a self-signed cert `Tidsmaskinen Self-Signed` in the user's login keychain (auto-created by the script via openssl + `security import` with `-legacy` flag for v1 PKCS#12 — the `security` CLI cannot verify v3/SHA-256 MAC PKCS#12 produced by OpenSSL 3 by default). The cert is untrusted (CSSMERR_TP_NOT_TRUSTED) but codesign uses it for signing regardless. Critical detail: this gives the .app a stable Designated Requirement (`identifier "se.forefront.tidsmaskinen" and certificate leaf = H"<cert sha1>"`) so TCC grants survive rebuilds. Pure ad-hoc signing (`--sign -`) gives every rebuild a different cdhash and TCC resets the grants.
- `Resources/Tidsmaskinen.entitlements` with `com.apple.security.automation.apple-events = true` — required because hardened runtime is on (`--options runtime`), and without that entitlement the system silently drops AppleEvents instead of prompting. For self-signed local dev builds the script also injects `com.apple.security.cs.disable-library-validation` into a *temporary copy* of the entitlements — the self-signed cert has no Team Identifier, so hardened runtime's library validation otherwise refuses to load Sparkle.framework. Release builds (real Developer ID, Team ID matches Sparkle's signature) get the original entitlements unchanged and stay strict.

Always test permission-related changes against the .app, never against the bare `swift run` binary.

### A dev instance beside the installed app

To look at a branch's UI while the installed app keeps recording, run

```sh
./bin/dev-instance.sh debug
```

It builds an ad-hoc-signed copy as `build/Tidsmaskinen Dev.app` (bundle id `se.forefront.tidsmaskinen.dev`), snapshots the live database with `sqlite3 .backup` into `build/dev-data/`, and launches the copy with `TIDSMASKINEN_DATA_DIR` pointing there. `AppPaths.supportDirectory()` honours that variable for the DB, the hook events log, and `KeychainStore.service` switches to a `.dev` namespace, so the copy never shares the live DB, never truncates the real `claude-events.jsonl`, and never triggers a keychain prompt for the installed app's tokens. `tm-hook` ignores the variable on purpose: hooks always write the real log. Stop the copy with `pkill -f 'Tidsmaskinen Dev.app'`. It has no TCC grants, so window titles are absent — it is for looking at screens, not for testing capture.

To navigate it without a mouse, compile `bin/devdrive.swift` (`swiftc -O -o build/devdrive bin/devdrive.swift`): `devdrive windows <pid>` lists its windows, `devdrive dump <pid>` lists pressable elements, `devdrive press <pid> "Review"` presses the first match by title/description, and `"<needle>#2"` targets the second match (a sheet's text field sits behind the sidebar's in walk order). Capture a window with `screencapture -x -o -l <windowID> out.png`, which works even when the window is behind others. Prefer this over synthetic clicks at screen coordinates: those go to whatever is in front, which may be the user's own app. Timeline blocks and agenda rows carry accessibility actions, so the reattribute popover can be opened this way too.

Stuck Automation prompt? `tccutil reset AppleEvents se.forefront.tidsmaskinen` clears the cached state so the next AEDeterminePermissionToAutomateTarget call re-prompts. The Diagnostics window has buttons for this.

### TCC grants do not transfer between dev and release builds

Self-signed dev builds and Developer ID release builds share the bundle ID but have *different* Designated Requirements (different certificate fingerprints). macOS TCC keys grants on the DR, so swapping one for the other looks like a brand-new app to the system — Accessibility grants in particular won't carry across. The fix is to remove the previous entry from `System Settings → Privacy & Security → Accessibility` before launching the other build, then re-grant. The same applies to Screen Recording. Automation (AppleEvents) usually re-prompts on its own; if it doesn't, run `tccutil reset AppleEvents se.forefront.tidsmaskinen`.

### Keychain prompt on every dev build

If codesign prompts for your login keychain password on every rebuild, the private key's *partition list* doesn't include `codesign:` — required since macOS Sierra. `ensure_signing_identity` in `bin/make-app.sh` now asks for your login password at cert-creation time and runs `security set-key-partition-list` once, so newly-created certs are silenced from the start. For an existing cert (created before this change), either delete the `Tidsmaskinen Self-Signed` identity from Keychain Access and let the script recreate it, or run this once:

```sh
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k <login-keychain-password> \
    "$HOME/Library/Keychains/login.keychain-db"
```

- macOS 26 (Tahoe) only. Swift 6.0+, single Swift Package (no Xcode project). The bundled `Info.plist` is generated by the script, not committed. Use the latest APIs freely — backward compat with previous macOS versions is a non-goal (this is an internal personal-use app).
- DB is in `~/Library/Application Support/Tidsmaskinen/db.sqlite` (WAL mode). Delete that file to wipe state.
- Always quit any existing instance before rebuilding the .app: menu bar icon → Quit, or `pkill -f Tidsmaskinen`.

## Layout

```
Sources/Tidsmaskinen/
  App.swift                 # @main, MenuBarExtra + Window scenes, AppDelegate sets .accessory policy
  AppRelocator.swift        # copies a release build from /Applications to ~/Applications so Sparkle updates need no admin
  AppState.swift            # @MainActor ObservableObject; owns AppDatabase + ActivityMonitor
  Settings.swift            # AppSettings (read) + SettingsKey constants; @AppStorage in views
  Capture/
    ActivityMonitor.swift   # 15s sample loop; reads AppSettings; sleep/wake hooks; idle via CGEventSource; stores the focused agent session on each sample
    AgentFocus.swift        # Claude desktop focus history from its own log (claude_focus_events), desktop session files → CLI session id, Codex threads by window title; backfills Claude samples (Codex resolves only at capture)
    Probes.swift            # AX focused-window title + AXDocument, Chrome URL via NSAppleScript, git root walker
    CaptureHealth.swift     # functional checks (AX trust, a real Apple event, Claude focus log, sign-in + sync age, hooks + events-log mtime, status-bar window, customers) probed on a timer; one notification on permission loss; feeds the tray and Settings › Setup
  Storage/
    Database.swift          # GRDB DatabaseQueue, versioned migrations, all CRUD + signal/meeting aggregations
    Models.swift            # ActivitySample (+ agentSessionID), Customer, Project, Rule (retired kinds listed in Rule.Kind.retiredRawValues), CalendarEvent, MeetingSeriesAttribution, ClaudeSession; MicSession is only the Slack title parsers old migrations call
  Attribution/
    RuleMatcher.swift       # samples: gitRepoSlug → gitRemoteHost → urlPath → gitRepoSlug again for a forge URL (github.com/owner/repo is that repo) → urlHost → appBundleID; a sample with an agent session goes manual → session pin → session repo rules first. events: per-event ignore → per-event override → series ignore → series rule. Returns EventAttribution enum for events.
    FocusTimeline.swift     # the billed timeline: MeetingBilling (booked meetings, overlap rule, double bookings) and FocusSpans (each sample until the next, minus meeting time)
    TimelineBlocks.swift    # builds per-track timeline blocks; skips ignored events; carries seriesMasterID; splits foreground blocks when the session or attribution changes
    WeeklyReport.swift      # bucketed (customer, project?) → per-day hours + TSV export; ignored events excluded; ReportRounding (nearest/up/down, day totals keep their true sum)
    ReviewQueue.swift       # ReviewQueue.rows classifies every item of a period (open / attributed+scope / ignored / ambient, per-day split); build = the open rows = the backlog the report and tray count
  Graph/
    GraphClient.swift       # MS Graph device-code OAuth + /me/calendarView fetch (incl. type, seriesMasterId)
    CalendarSync.swift      # diff fetched against existing in range; preserves customerID/projectID/isIgnored
  UI/
    MenuBarView.swift       # tray: week line, live capture status, banners with fixes, Now card, health stripe, Review/Report/My day
    SamplesDebugView.swift  # raw activity samples table
    SettingsView.swift      # @AppStorage-driven Form
    ReviewView.swift        # one list of everything with time in the week (Open / All / Ignored) + detail pane; keyboard triage; absorbed the old Discover screen
    CustomersView.swift     # rules CRUD
    TimelineView.swift      # per-day timeline; ReattributePopover with series-aware actions on calendar blocks
    AttributionPickerSection.swift  # shared customer+project picker (CC sections, + New, CC-aware disable)
    WeeklyReportView.swift  # weekly grid + Copy as TSV
plans/master-plan.md        # full design doc
```

## Commit & PR Style

Never add `Co-Authored-By` trailers or AI-attribution footers (e.g. "🤖 Generated with Claude Code") to commit messages or PR bodies. Commits and PRs should read as if the human authored them.

## Conventions

- **Compatibility policy (2026-09-19)**: prefer a clean change across the app and all callers over obsolete runtime compatibility branches. Preserve recorded history, manual assignments, and installed hooks; do not reset user data as cleanup. Keep schema migrations and historical readers where needed for retained data. New internal APIs should require the context they need instead of providing a fallback that silently restores incorrect old behavior.

- **Billed time is focus (2026-11-27)**: `WeeklyReport`, `ReviewQueue` and My day's day stats lay time on one timeline via `Attribution/FocusTimeline.swift`. Eligible meetings (not declined, not all-day, not ignored) bill their *booked* time and own their slot; in an overlap accepted/organizer beats tentative/unanswered, and two of the same standing both bill in full (even for one customer) until the user picks one in Review (`meeting_overlap_choices`, `MeetingBilling.DoubleBooking`). Each active sample bills from its capture until the next sample (of any kind) or one interval, minus every eligible booking's full span (`MeetingBilling.blocked`) — so parallel samples can't double count. Agent runtime bills nothing; `WeeklyReport.agentHoursByRowID` carries hook activity as context, shown beside rows in the report. Claude/Codex samples carry `agentSessionID` (`AgentFocusRecorder`): Claude's from `LocalSessions.setFocusedSession` lines in `~/Library/Logs/Claude/main*.log` (copied into `claude_focus_events` because the log rotates after ~3 weeks; `sessionId=null` = Chat tab or another view; a `startup-perf` line resets focus to unknown), Codex's from the window title matched to exactly one user thread in `~/.codex/state_<n>.sqlite`, at capture only (a renamed thread could hand an old title to other work). While the log reader is scanning or behind, a Claude sample gets no session; a backfill bounded by how far the stored history reaches fills it in. A focused session with no hook row gets a placeholder `claude_sessions` row (`insertSessionIfAbsent`, `lastActivityAt == nil`); `HookIngester` treats such a row as not started, so its invented bounds never reject real hook events. `RuleMatcher.attribute(_:)` resolves a sample: manual assignment → the session's pin → the session's repo rules at the *sample's* time → the app's own rules. Nothing is guessed: a sample whose session can't be read keeps none. Review lists focus on a session with no git repo as an `.agentSession` row (Confirm pins the session) and unresolved double bookings as `.doubleBooking` rows. Use `WeeklyReport.load(from:week:matcher:...)` rather than assembling inputs by hand.

- **Settings**: anything user-tunable goes through `Settings.swift`. Add a key in `SettingsKey`, a default-respecting accessor in `AppSettings`, and a SwiftUI binding via `@AppStorage(SettingsKey.x)` in views.
- **Schema changes**: register a new migration in `Database.swift` (`v4_…`, `v5_…`); never edit prior migrations. SQLite ALTER TABLE can add nullable columns and create indexes; can't add FK constraints — enforce those at the app level.
- **Don't track ourselves**: `ActivityMonitor.captureNow()` skips when `frontmost.processIdentifier == ownPID`. Preserve this if you refactor.
- **Probe permissions**: `Probes.windowTitle` and `windowDocumentPath` short-circuit when `AXIsProcessTrusted` is false. AppleScript probes (Chrome) trigger Automation prompts on first call. Don't call probes outside the relevant frontmost-app branch — it surfaces unwanted prompts.
- **GRDB upserts**: records are value types but `upsert(_:)` mutates `id` on insert. Always declare a local `var` copy inside `dbQueue.write { ... }`.
- **Rule kinds**: repo slug, remote host, URL host, URL path and app bundle id, all glob (`*` wildcard). Retired kinds (`windowTitle`, `slackChannel`, `participant`, and earlier the email domain) keep their rows in the database but every rule query filters on `Rule.Kind.activeRawValues`, so a leftover row can never fail decoding (`RetiredRuleKindsTests`). Meeting attribution is explicit (see below).
- **Customer vs project**: rules can target a `customer` alone or a `(customer, project)` pair for any kind. Review's detail pane exposes the project picker for every kind once a customer is chosen.
- **Meeting attribution**: calendar events do *not* auto-match from attendee domains. Attribution is explicit, per-event or per-series:
  - Recurring series: assign once in Review (a series row; scope Always writes the series attribution, This week / This day write per-occurrence overrides for that window), or from the Timeline popover via "Apply to series" — the default button there. Stored in `meeting_series_attributions` keyed by Graph's `seriesMasterId`. Every occurrence (including Graph `exception` rows) inherits the series rule.
  - Single occurrences override the series via `CalendarEvent.customerID`/`projectID` ("Save for this meeting").
  - Either an event or a whole series can be **ignored** (e.g. lunch holds). Ignored items are hidden from Timeline and excluded from the weekly report; Review's Ignored filter lists and restores them (as it does hidden repos, hosts, apps and ignored calls).
  - `RuleMatcher.attribute(event:)` returns `EventAttribution` (`.attributed(source: .event|.series)`, `.ignored(source:)`, `.unattributed`). `WeeklyReport.collectRecords` skips ignored events; `TimelineBlocks` skips them too.
- **Calls and Slack are gone (phase 2 of the focus rework)**: `MicMonitor`, the Calls tab, call rows in Review, the report's call source, meeting overrun and mic ownership, participant and Slack-channel rules, Slack title parsing for attribution, the call health check and the Diagnostics call UI probe were removed. The `mic_sessions` table and its rows stay, unread. `MicSession` survives only as the Slack huddle-title parsers that migrations v13, v15, v16 and v21 call — never edit those migrations. Cells calls replace this in phase 3.
- **Review backlog cache**: `ReviewQueue.rolling` resolves every sample of the current plus four earlier weeks, so it is not recomputed per sample. `AppState.currentReviewBacklog()` caches the result for `reviewBacklogMaxAge` (5 min), shares one in-flight computation, and is invalidated by Review's writes and by calendar / Command Center syncs; the menu-bar glance and Review's landing week both read it, so they always agree. Writes from Timeline and Calls only expire via the max age. `rolling` counts each unit id once across weeks (a boundary-crossing call is queued clipped in both weeks) and the oldest week owns it.
- **What a hide means**: hiding an app in Review hides only its *app-only* time (no repo, no site); hiding a host hides that site; repo time is never hidden (ignored repos are dimmed in My day and skipped by the report). `TimelineBuilder.visibleSamples` is the one filter My day uses, matching `ReviewQueue.rows`; the report ignores hides altogether. Dropping every sample of a hidden app once emptied My day's foreground lane for anyone who hid Chrome.
- **Review is one list, resolved per sample**: `ReviewQueue.rows` attributes every sample and meeting at its own timestamp and aggregates per signal, so a row shows the attribution that actually covers its time in the period and the scope it was written with ("Always", "This week", "This day", "Manual", "Series", "This meeting", or "Mixed" when the period splits). App-only time is `.ambient`: listed under Apps & sites and assignable (an app rule), but deliberately never part of the open count — an editor or browser can't be pinned to one customer, so it would nag forever. Rows under `reviewMinMinutes` are `belowThreshold`: hidden behind the "N under 5 min hidden · show" toggle and never counted; My day's agenda applies the same rule to its open rows (`isShort`, with its own reveal toggle), so the two lists agree on what is noise. The scope Review preselects is `ReviewUnit.defaultScope`: Always for repos, hosts, paths and series, This week for an app (ambient), Just this for an agent session (a pin) and a double booking (answered with its own buttons). Review reloads after every write and keeps its selection by row id; Undo (⌘Z) pops a stack of units and deletes exactly the rule that Confirm wrote (`writtenRules`), un-hides, clears the attribution, or restores a session's previous pin. Single-key shortcuts (J K H E 1–3 / ?) are disabled while the search field has focus.
- **Review evidence and previews**: `ReviewQueue.rows` also returns `ReviewRow.evidence` — the three longest stretches of consecutive samples on a signal (a gap over `evidenceGapSeconds` = 2 min starts a new one; open rows list only open stretches), each with the window title (URL path for a host) seen most, which the detail pane links into My day (the block covering that moment is selected and its popover opened, via `timelineTargetDay` carrying a time), plus a remainder line for the shorter stretches so the card sums to the header. A host becomes a host group with per-path assign rows for every open path of a minute or more; the review threshold gates the host, not its paths. Suggestions are earlier answers for the pattern, then where the host's paths already go, then the customers with the most attributed time in the period. Review's decision note names an existing rule for the same pattern by another customer (`existingRuleNote`) and, for Always, what the rule also clears in the other weeks of the backlog window (`loadImpact`, resolved off the main thread per selection). Assigning a whole host warns when the host is in `sharedHosts` (localhost, Microsoft/Azure portals, GitHub, Atlassian) or already ruled to a customer — the paths are the right unit there. The Customers rule editor previews what a pattern matches in the last 90 days via `AppDatabase.ruleMatchCount` (grouped by signal column, then `RuleMatcher.matches` per distinct value; calls counted from mic sessions).
- **Graph rows with unparseable dates** are skipped, not fatal: `GraphClient.fetchCalendarView` returns them in `CalendarFetch.skippedIDs` and `CalendarSync` treats them as fetched so the orphan pass never deletes their local copy. Cancelled events are dropped before validation.
- **Capture health is verified, never cached**: `CaptureHealth.probe()` runs every minute, on activation, after sign-in/sign-out and every calendar sync, and when the tray or Settings › Setup opens. Add a new dependency as a `Check` there; the tray stripe, banners, tray-icon dot and the Setup pane's rows and actions all derive from it. The menu-bar check reads the status-bar window (ordered in with a width) and only warns. The Claude focus check verifies Claude's log is still readable and still naming sessions after Claude starts.
- **Weekly report rounding**: `WeeklyReport.compute(rounding:)` rounds every cell to a quarter hour in the chosen `ReportRounding` (setting `reportRounding`, default nearest) and then keeps each day's true total by putting the residue on that day's largest bucket, so the column sum never drifts from reality (`ReportRoundingTests`). `Row.rawPerDayHours` keeps the unrounded cells for hover. A week can be **marked reported** (`reported_weeks`, migration v23): the report then shows the filed total and flags when the current total differs, so a late sync can't silently change a number already filed. The report's day headers link into Review scoped to that day (`AppState.reviewTargetDay`) and cells open that day in My day (`timelineTargetDay`).
- **Rules carry no visible priority**: every rule is written at 100 and the matcher's specificity order decides; Customers describes each pattern in words ("always · most specific wins", "week 38 only · expires Sun") and groups week-bounded rules on one pattern into a stack with "Make permanent" (confirmed with a preview). Patterns also claimed by another customer are flagged there at read time.
- **Shared attribution picker**: every "assign customer/project" UI uses `UI/AttributionPickerSection.swift` — CC/Local sections, `+ New` inline creation, `+ New Project` disabled (with help text) under a Command Center customer. Use this in any new attribution sheet rather than rolling another picker. Inline creation calls `AppDatabase.createLocalCustomer` / `createLocalProject`.

## Phases

`plans/master-plan.md` defines the phased plan. Capture, rules, reports, calendar sync, Claude/Codex hook ingestion, and explicit meeting attribution are implemented. The original master plan also contains unimplemented proposals (see its current-status section), plus the post-Phase-4 attribution rework that swapped meeting-domain auto-matching for explicit per-series / per-event attribution (see "Meeting attribution" under Conventions). When you start work, check the master plan for current scope; do not invent new phases without updating the plan.

## Releasing

Cutting a release is one `git push`:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The `.github/workflows/release.yml` workflow then signs (Developer ID), notarizes, packages, publishes a GitHub Release with `Tidsmaskinen.zip` attached, deploys `appcast.xml` plus the zip to GitHub Pages, verifies the zip is reachable, and only then appends the new `<item>` to `appcast.xml` on `main` (`bin/update-appcast.sh` inserts it just before `</channel>`, so the file is oldest first; Sparkle picks the highest `sparkle:version`, not the first item). Installed apps pick up the new version on their next Sparkle check (daily) or when the user clicks "Check for Updates" in the menu bar.

`bin/make-app.sh` keeps its local-dev defaults (self-signed, no notarization, no Sparkle keys) and only switches behaviour when these env vars are set:

| Env var | Purpose |
|---|---|
| `VERSION` | Bundle version baked into Info.plist (defaults to `0.1.0-dev`) |
| `SIGNING_IDENTITY` | Developer ID CN, e.g. `Developer ID Application: Forefront AB (TEAMID)` |
| `NOTARIZE` | `1` triggers `notarytool submit --wait` + `stapler staple` + a re-zipped `build/Tidsmaskinen.zip` |
| `SPARKLE_PUBLIC_ED_KEY` | base64 EdDSA public key; enables the `SU*` Info.plist keys |
| `SPARKLE_FEED_URL` | override the default appcast URL |
| `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID` / `APPLE_API_KEY_PATH` | App Store Connect API key for notarytool |

One-time setup (already done if the workflow has run successfully):

1. **Developer ID Application** cert from the Apple Developer portal → export as `.p12` → base64-encode → store as the `MACOS_CERT_P12_BASE64` secret along with `MACOS_CERT_P12_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID`.
2. **App Store Connect API key** (Developer role) → store contents as `APPLE_API_KEY_P8` plus `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID` secrets.
3. **Sparkle EdDSA key pair** — run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once (private key lands in the login keychain). Re-export with `generate_keys -x sparkle_ed_private_key`, base64-encode the file, store as the `SPARKLE_ED_PRIVATE_KEY` secret. The matching public key (printed by `generate_keys`) goes into the `SPARKLE_PUBLIC_ED_KEY` GitHub Variable.

`appcast.xml` lives at the repo root; the release workflow rewrites it. Don't hand-edit it. Rolling back means cutting a new, higher version: Sparkle never downgrades, and only the newest zip is hosted.

**Update feed hosting.** Installed apps read `https://forefront-ignite.github.io/tidsmaskinen/appcast.xml` and download `…/releases/v<version>/Tidsmaskinen.zip` from the same GitHub Pages site (`SUFeedURL` default in `bin/make-app.sh`, enclosure base in `bin/update-appcast.sh`). Pages stays public even when the repository is private, which is why the feed no longer points at `raw.githubusercontent.com` or at GitHub Release assets — both 404 anonymously on a private repo. Each Pages deploy replaces the whole site, so only the newest zip is hosted; Sparkle only ever downloads the highest-versioned item, which is the last one in the file. Setup that already exists and must survive: Pages source = "GitHub Actions" (`gh api -X POST repos/Forefront-Ignite/tidsmaskinen/pages -f build_type=workflow`), and the auto-created `github-pages` environment must allow deployments from `v*` tags (its default only allows `main`). GitHub documents that making a repo private unpublishes its Pages site; after flipping, check `gh api repos/Forefront-Ignite/tidsmaskinen/pages` and, if it is gone, re-enable it with the same command and cut a new tag so the site is redeployed. Builds ≤ 0.3.15 still read the old raw URL, which only works while the repo is public.

**Install location.** Sparkle updates without an admin prompt only when the bundle *and its parent folder* are writable by the user and the bundle is user-owned. `/Applications` is `root:admin`, so on standard-user Macs (Admin By Request) every update prompted. Users are told to install to `~/Applications` (README, release notes), and `AppRelocator.run()` (called from `AppDelegate`) offers to relocate a release build sitting **directly in `/Applications`** and whose install folder belongs to someone else (`installFolderIsNotOurs`). Only that folder earns an elevated delete: it is `root:admin`, so its entries can't be swapped by anything running as the user. A *nested* folder does not qualify: installers ship world-writable ones (`/Applications/Hearthstone` is 0777), so an ancestor the user can replace would put the path back in their hands. An install elsewhere can be moved by its owner with no rights at all. It **copies** itself there unprivileged, then elevates for one `rm -rf` of the old copy. Writing into the user's own home needs no rights, and `/Applications` is `root:admin`, so no root operation touches a path anything running as the user could swap; an elevated `mv`/`chown` reaching into `~/Applications` was a root-level TOCTOU. Elevation goes through `do shell script … with administrator privileges`, i.e. the `system.privilege.admin` right, which ABR wraps. The pending-repair flag is written before elevating, so a crash between the delete and the relaunch still repairs on the next launch; a cancelled or failed removal deletes the copy again and clears it, but *only* when the old bundle is still intact (`oldCopyIsIntact`, a signature check — `rm -rf` is not transactional, and undoing the copy after a partial delete would leave no working app at all). It then relaunches, re-registers the login item and reinstalls any coding-agent hooks left pointing at the old path (they record an absolute `tm-hook` path, so relocating silently kills session capture otherwise). Dev builds have no `SUFeedURL` and are never relocated. "Don't ask again" is `defaults delete se.forefront.tidsmaskinen relocationPromptSuppressed` to undo. An existing `~/Applications` copy must satisfy this build's designated requirement before it is replaced, so a *dev* copy there is refused ("can't be verified") when a release build tries to move in: remove it by hand. The Sparkle updater is held back while the prompt is open (`AppRelocator.shouldHoldUpdater`, released via the `didSettle` notification) so an update can't install into the bundle being replaced. The trigger deliberately does **not** mirror Sparkle's own writability test. Admin By Request grants a temporary admin session for the very update that relaunches the app (and users often pre-start one before upgrading), during which `/Applications` is writable, so a writability check concludes no move is needed exactly when it is. Ownership does not move with the session. This shipped broken in v0.3.16: the prompt never appeared.

## What this app deliberately does NOT do

- No cloud sync. Everything is local.
- No always-on screen recording. Just frontmost app metadata + window title + git remote.
- No automatic billing or invoicing — output is TSV/grid that the user pastes into Forefront's reporting tool.
- No support for non-macOS platforms.
