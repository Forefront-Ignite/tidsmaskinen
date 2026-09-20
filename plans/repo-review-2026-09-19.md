# Repository review and cleanup — 2026-09-19

Reviewed the Swift app, settings, capture and hooks, storage and migrations, attribution and reports, SwiftUI flows, Microsoft Graph and Command Center integrations, packaging/release scripts, tests, and project documentation. Three parallel reviewers covered capture/settings, attribution/storage, and UI; the main reviewer covered integrations/releases and checked the combined changes.

## Fixed findings

| Area | Finding and correction |
|---|---|
| Settings | Three controls had no runtime readers: parallel attribution, idle tracking during meetings, and attendance verification. Removed the controls and dead accessors; described actual behavior instead. |
| Settings | Selecting the Custom Microsoft preset did not reliably enable its fields. Made the selection reactive. Permission/startup status refreshes on app activation. |
| Settings | Command Center claimed credentials never leave the Mac. Corrected the copy: Keychain storage, bearer authentication to the configured API. Ignored-item errors are now visible. |
| Calendar sync | Only the first 200 events were fetched before deleting apparent server orphans. Follow all pages and reject incomplete/malformed snapshots before changing local rows. Pagination URLs must remain on Microsoft Graph. |
| Calendar sync | Changing RSVP filters deleted excluded meetings and their assignments. Store the complete snapshot and filter on local reads. Cancelled meetings are excluded. |
| Calendar sync | Unrelated defaults changes restarted the timer, including after sign-out. Rearm only an enabled sync when its interval changes. |
| Microsoft OAuth | Form encoding left reserved token characters unescaped. Encode form values correctly. Device-code slow-down now accumulates and persists across pending responses. |
| Command Center | Archived rows were excluded from lookup, making resurrection unreachable and risking duplicate identities. Reuse original IDs; reactivate/rename parents recovered through engagements. |
| Attribution | Archived customers/projects vanished from rule resolution, changing historical reports. Include archived entities in matching while keeping assignment pickers active-only. |
| Meetings/calls | Ignored recurring series and declined bookings could absorb calls. Ownership now requires the full matcher and rejects both. Declined meetings do not bill or enter Review. |
| Date boundaries | Meetings and calls beginning before a selected interval were omitted. Use overlap queries; clip displayed call segments and Review totals to the selected period. |
| Coding activity | Idle-clamped activity was placed at the end of the gap, sometimes on the next day. Place new deltas immediately after the prior activity. Ignore stale events that would rewind the cursor and double-count time. |
| Coding activity | Discover/Review counted lifetime session totals in each overlapping period; reports could miss midnight-spanning deltas or invoke historical fallback for a quiet modern session. Load activity for overlapping sessions and clip it to each period. |
| Capture | Concurrent first hooks could truncate a newly created log. Create/open atomically. File-watcher cancellation now closes its own descriptor. |
| Microphone | Calls could span laptop sleep and count the whole gap. Close sessions at sleep, suppress polling while asleep, and resume on wake. |
| Review | Scoped rules were checked at the interval start instead of each sample's timestamp. Resolve before grouping, respect manual overrides, and exclude individually assigned/ignored meeting occurrences. |
| Review | Multiple short browser paths could suppress a meaningful host backlog. Keep the host assignable when no individual path meets the threshold. |
| UI dates | Historical Discover assignments targeted today; changing Review weeks retained the old day; initial background lookup could override navigation. Anchor scopes correctly and cancel/reject stale lookup results. |
| UI errors | Assignment dialogs dismissed on failed writes; several screens presented query failure as no activity/all reviewed. Keep failed dialogs open and surface errors. |
| UI freshness | Discover path totals and several views stayed stale after integration sync. Invalidate cached paths and refresh relevant views. Clear unavailable customer selections. |
| Atomic saves | A call assignment could persist without its requested rule, or a series could be partly assigned. Save each operation in one transaction. |
| Git parsing | SSH URLs with an explicit port produced incorrect repo slugs. Use URLComponents for URL syntax and a separate scp-style parser. |
| Releases | Tagged releases built current main rather than the tag, and advertised updates before upload. Build/test the tag, upload first, then update the feed; serialize release jobs. |
| Documentation | The master plan presented unimplemented proposals as current behavior. Added an explicit shipped/proposed distinction and documented actual settings/accounting behavior. |

## Cleanup and compatibility decisions

Removed the unused foreground Teams-session implementation, unused microphone-device probes, unused design-system helpers/sidebar styling, and a redundant menu query. Internal mic-accounting APIs now require attribution context; there is no optional fallback to the old behavior.

Preserved schema migrations, stored assignments/history, existing installed hook formats, and the pre-delta session reader. These protect actual persisted data and working installations. Removed settings defaults may remain harmlessly in UserDefaults; no reset is needed. No compatibility framework or dual-write path was introduced.

## Validation

Regression coverage exercises pagination failures and override preservation, RSVP filter changes, archived-entity resurrection, scoped attribution, ignored/declined meeting ownership, interval boundaries, atomic save rollback, coding-session accounting, microphone sleep closure, and date-scope selection. `swift test` passes all 80 tests (57 originally, 23 new regressions). `swift build -c release` also passes for the app and `tm-hook`. `git diff --check` and shell syntax checks pass.

The Graph checks use a local URLProtocol fixture and in-memory databases. They do not contact the user's Microsoft account. Shell scripts receive syntax checks; release workflow changes receive structural inspection.

## Limits and follow-up checks

- Native visual interaction, TCC permission prompts, real microphone/sleep transitions, live account sign-in, and signed/notarized release installation were not exercised. Verify those against a signed `.app` before releasing.
- Previously mispositioned coding activity remains untouched: the database does not reliably retain the original event timing needed to repair it without guessing.
- The original all-day calendar and parallel-accounting policies remain; this cleanup does not redefine what should be billable.
- Startup database-open failure still terminates the app. A recovery UI would be a separate feature and must not automatically reset history.

Microsoft Graph pagination behavior was checked against [Microsoft's paging documentation](https://learn.microsoft.com/en-us/graph/paging); device-code polling against [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628).
