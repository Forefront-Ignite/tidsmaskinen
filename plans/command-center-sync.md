# Command Center customer + project sync

Pull clients and projects from the Forefront Command Center backend
(`https://api.ignitestudio.eu`) so the user doesn't have to type them in by
hand. Locally-created customers/projects keep working; imported ones are
read-only in our UI and visually distinguished.

Command Center repo: `/Users/niklas.salarp/Dev/Forefront/Ignite/command-center/`
(monorepo; backend = `apps/backend`, hand-maintained API client =
`packages/api-client/src/client.ts`).

## What we want to consume

From `client.ts`:

- `GET /planning/clients?status=…` → `ListClientsResponse { clients: ClientRow[] }`
  ```ts
  ClientRow {
    id: string
    name: string
    orgNumber: string | null
    contactName: string | null
    contactEmail: string | null
    notionPageId: string | null
    intelligenceCustomerId: string | null
    status: string         // "active", "prospect", "inactive" (filter to "active")
  }
  ```
- `GET /planning/projects?status=active&clientId=…` → `ListProjectsResponse { projects: ProjectListItem[] }`
  ```ts
  ProjectListItem {
    id: string
    name: string
    clientId: string | null
    engagementType: string  // "tm" | "fixed_price" | "retainer" | "prospect" | "internal"
    status: string
    color: string | null
    // (plus budget/owner/hours fields we ignore)
  }
  ```

For the time-report use case we only need: `id`, `name`, `clientId`, `status`,
`color`, plus `engagementType` so we can hide `"prospect"` (sales pitches) by
default. Everything else we drop on the floor.

We do **not** push anything back to Command Center — this is read-only.

## Auth

Bearer token in the `Authorization` header. The backend side (registering
Better-Auth's `apiKey` plugin, the mint CLI, the migration) is tracked
separately in command-center's repo: **`plans/api-key-auth.md`** there. Run
that work in parallel; the contract this plan depends on is:

- Tokens look like `cc_<base64>` and live forever until explicitly revoked.
- Sending `Authorization: Bearer cc_…` against any `/planning/*` endpoint
  resolves to the token's owning user (same access as a logged-in session).
- A CLI script mints them: `bun run mint-token <email> "<label>"` printed
  to stdout once.

### Tidsmaskinen-side flow

- Settings → **Command Center** section: a single `SecureField` "Paste API
  token" + Save button. Token is stashed in Keychain under
  `command-center-token` using the existing `KeychainStore` helpers from
  `Sources/Tidsmaskinen/Graph/KeychainStore.swift`.
- Below the field, a short instruction line: "Ask Niklas for a token, or
  run `bun run mint-token` in the command-center repo." (Replace with a
  deep link once command-center ships a `/settings/api-tokens` portal page
  — tracked in the CC plan's "Future" section.)
- `Sources/Tidsmaskinen/CommandCenter/CommandCenterClient.swift` — actor
  with `listClients()` / `listProjects()`. Plain `URLSession.shared.data(for:)`
  with `request.setValue("Bearer \(token)", forHTTPHeaderField:
  "Authorization")`. Decoders match the shapes above — don't port the whole
  4.6k-line TS client.
- On `401`/`403` → mark `state.commandCenter.tokenInvalid = true`, surface a
  banner in the Customers window with "Update token" pointing at Settings.

No WKWebView, no cookie jar, no per-request session refresh.

## Data model changes

We don't shadow upstream rows in a separate table — that splits the rule
matcher, the report aggregator, and the picker into "is it local? is it CC?"
forks everywhere. Instead, tag the existing rows.

Migration `v6_external_source` in `Storage/Database.swift`:

```sql
ALTER TABLE customers ADD COLUMN externalSource TEXT;       -- null | 'command-center'
ALTER TABLE customers ADD COLUMN externalID TEXT;           -- CC ClientRow.id
ALTER TABLE customers ADD COLUMN externalSyncedAt DATETIME;
CREATE UNIQUE INDEX idx_customers_external
  ON customers(externalSource, externalID)
  WHERE externalSource IS NOT NULL;

ALTER TABLE projects ADD COLUMN externalSource TEXT;
ALTER TABLE projects ADD COLUMN externalID TEXT;
ALTER TABLE projects ADD COLUMN externalSyncedAt DATETIME;
ALTER TABLE projects ADD COLUMN engagementType TEXT;        -- carried from CC for filtering
CREATE UNIQUE INDEX idx_projects_external
  ON projects(externalSource, externalID)
  WHERE externalSource IS NOT NULL;
```

In `Storage/Models.swift`:

```swift
struct Customer {
    // existing fields ...
    var externalSource: String?      // "command-center" or nil
    var externalID: String?
    var externalSyncedAt: Date?

    var isExternal: Bool { externalSource != nil }
}

struct Project {
    // existing fields ...
    var externalSource: String?
    var externalID: String?
    var externalSyncedAt: Date?
    var engagementType: String?      // "tm", "fixed_price", "retainer", "prospect", "internal" (CC only)

    var isExternal: Bool { externalSource != nil }
}
```

Rules continue to reference customers/projects by local `id`. A rule can target
either a CC-imported customer or a local one — the matcher doesn't care.

## Sync logic

`Sources/Tidsmaskinen/CommandCenter/CommandCenterSync.swift`, called:

1. On Customers window open (debounced — skip if last sync < 5 min ago).
2. On a manual "Sync now" button in Settings → Command Center section.
3. On app launch (best-effort, ignore errors).
4. Hourly timer when the app is foreground.

Algorithm:

```
fetch clients (status=active)
fetch projects (status=active)

for each CC client c:
  match existing local customer where externalSource='command-center' and externalID=c.id
  if found: update name/orgNumber metadata, set externalSyncedAt=now
  else: insert new Customer(id=UUID, name=c.name, color=null,
                            externalSource='command-center', externalID=c.id, ...)

for each CC project p:
  resolve customerID = local customer with externalID=p.clientId (skip if missing)
  match existing local project where externalSource='command-center' and externalID=p.id
  if found: update name/color/engagementType/customerID
  else: insert new Project(...)

# Soft-deletion: CC rows that vanished (status changed off "active", or got hard-deleted)
mark customers/projects with externalSource='command-center' and externalID NOT IN (returned ids)
  as externalSource='command-center-archived'    # keep historical reports intact
```

We never delete external rows that disappear upstream — they could still have
historical rules and time entries pointing at them. We just downgrade them to
`command-center-archived` and hide them from pickers.

## UI changes

**Visual distinction (read-only badge).** Anywhere a customer or project is
rendered:

- Prefix the row with a small `building.2` SF Symbol when `isExternal` is true
  (use `link` if `building.2` reads as too generic).
- Append a subtle "Command Center" tag (`Text("CC").font(.caption2)` in a
  capsule with `tertiary` style) on the right side.
- Sidebar rows in `CustomersView`: keep the color dot, append the badge after
  the name.

**Read-only behavior in `CustomersView`:**

- Sidebar context menu: hide "Delete" for external customers (instead show
  "Hide from picker" → just marks `externalSource='command-center-archived'`
  locally without touching CC).
- Detail pane: name field becomes a non-editable label with a small
  `info.circle` tooltip "Synced from Command Center" — but rules can still be
  added/edited (rules are local-only).
- Project list under detail: external projects show the badge; the "+ New
  project" button only adds local projects (still allowed alongside CC
  projects under the same customer — useful when CC doesn't track the
  internal sub-project we care about).
- New customer text field still works for purely local customers.

**`DiscoverView` "Assign…" sheet:** when picking a customer/project, group the
options:

```
── Command Center ──
  Acme Corp           CC
  Beta Industries     CC
── Local ──
  Personal projects
  + New customer…
```

External entries selectable but not editable from the sheet's inline "+ New"
flow.

**Settings → new "Command Center" section** (`SettingsView.swift`):

- "Sign in to Command Center" / "Signed in as …@forefront.se" + "Sign out"
- Toggle: "Sync customers & projects automatically" (default on)
- "Last synced: 14:32" + "Sync now" button
- "Include prospect projects" toggle (default off — filters out
  `engagementType=prospect`)
- Read-only count: "23 customers, 41 projects from Command Center"
- Banner if `sessionInvalid`: red row with "Session expired — sign in again"

**Settings keys** (`Settings.swift`):

```swift
enum SettingsKey {
    // existing keys ...
    static let commandCenterEnabled            = "commandCenterEnabled"            // Bool, default true
    static let commandCenterIncludeProspects   = "commandCenterIncludeProspects"   // Bool, default false
    static let commandCenterBaseURL            = "commandCenterBaseURL"            // String, default "https://api.ignitestudio.eu"
    static let commandCenterLastSyncAt         = "commandCenterLastSyncAt"         // Date, set by sync
}
```

Base URL is configurable so local dev against `http://localhost:4000` works.

## Files

```
Sources/Tidsmaskinen/CommandCenter/
  CommandCenterClient.swift     # actor with listClients() / listProjects()
  CommandCenterSync.swift       # diff + upsert into local DB
  CommandCenterModels.swift     # Decodable CCClient, CCProject — only the fields we use
Sources/Tidsmaskinen/UI/
  SettingsView.swift               # +section with token field
  CustomersView.swift              # +external badges, +read-only guards
  DiscoverView.swift               # +grouped picker
Sources/Tidsmaskinen/Storage/
  Database.swift                   # +v6 migration, +archived filtering in pickers
  Models.swift                     # +external fields
```

Backend-side files (apiKey plugin, mint CLI, migration) are tracked in
command-center's `plans/api-key-auth.md`.

## Edge cases

- **Name collision with existing local customer.** If "Acme Corp" already
  exists locally and CC sync brings in "Acme Corp" with a CC id, do NOT
  auto-merge. Insert as a separate row (the unique index is only on
  name=non-external rows — drop the existing `unique` on `customers.name`
  in v6 since externals can legitimately share names with locals during
  transition). Add a one-time "Merge with Command Center entry?" suggestion
  in the Customers window: if a local customer's name matches an external
  one (case-insensitive trim), show an inline "Merge → CC" affordance that
  rewrites rules to point at the CC customer's id and deletes the local one.
- **CC project moved to a different client.** Re-upsert handles this — we
  reset `customerID` to the new resolved local customer. Rules pinned to
  `projectID` keep working; rules pinned to old `customerID` get orphaned
  (acceptable — surfaces the change to the user).
- **Offline / 401.** Surface the banner; do nothing destructive. The local DB
  keeps the last-known CC rows so reports still resolve.
- **Color conflict.** CC projects may set `color`. Prefer CC's color when we
  insert; on update, keep the user's local override if they changed it. Use
  a `colorUserModified: Bool` flag, or just store CC's color in
  `externalColor` and resolve to `color ?? externalColor` at display time
  (simpler — go with the latter).

## Verification

Preconditions (delivered by command-center's `plans/api-key-auth.md`):
- Bearer-token auth works against `/planning/clients` and `/planning/projects`.
- `bun run mint-token` prints a usable token.

Tidsmaskinen-side:

1. Local DB migration (`v6_external_source`) runs cleanly on the existing
   dev DB.
2. Paste token into Tidsmaskinen → Settings; "Sync now" populates customers
   + projects; counts match the portal.
3. CC rows display the badge and have edit/delete disabled.
4. A rule pointed at a CC customer still attributes activity correctly in
   the weekly report.
5. Adding a local customer alongside CC ones still works; the unique-name
   constraint doesn't fight us.
6. Revoke the token on the backend → next sync surfaces the 401 banner;
   pasting a fresh token restores the flow.
7. Toggling "Sync automatically" off stops the hourly poll (verified by
   stopping the timer, not just hiding the button).

## Out of scope (for now)

- Writing back time entries to CC's `/planning/time-entries` endpoint. The
  master plan still ships TSV export; that's enough.
- Pulling assignments, retainers, change requests, budget tracking — could be
  useful later for sanity checks but not for the core mapping flow.
- Two-way merge UX (merge two existing locals into one). Manual delete +
  re-attribute is fine for v1.
