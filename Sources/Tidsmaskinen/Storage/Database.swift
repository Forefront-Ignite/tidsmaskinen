import Foundation
import GRDB

struct AppDatabase {
    let dbQueue: DatabaseQueue

    static func shared() throws -> AppDatabase {
        let url = try Self.databaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        let db = AppDatabase(dbQueue: queue)
        try db.migrate()
        return db
    }

    static func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("Tidsmaskinen", isDirectory: true)
            .appendingPathComponent("db.sqlite")
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_activity_samples") { db in
            try db.create(table: "activity_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("capturedAt", .datetime).notNull().indexed()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("windowTitle", .text)
                t.column("chromeURL", .text)
                t.column("chromeHost", .text)
                t.column("gitRepoPath", .text)
                t.column("gitRemoteURL", .text)
                t.column("isIdle", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v2_customers_and_rules") { db in
            try db.create(table: "customers") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("color", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "rules") { t in
                t.primaryKey("id", .text)
                t.column("customerID", .text).notNull()
                    .references("customers", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_rules_kind", on: "rules", columns: ["kind"])
            try db.create(index: "idx_rules_customerID", on: "rules", columns: ["customerID"])
        }
        migrator.registerMigration("v3_projects") { db in
            try db.create(table: "projects") { t in
                t.primaryKey("id", .text)
                t.column("customerID", .text).notNull()
                    .references("customers", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_projects_customerID", on: "projects", columns: ["customerID"])
            try db.alter(table: "rules") { t in
                t.add(column: "projectID", .text)
            }
            try db.create(index: "idx_rules_projectID", on: "rules", columns: ["projectID"])
        }
        migrator.registerMigration("v4_calendar_events") { db in
            try db.create(table: "calendar_events") { t in
                t.primaryKey("id", .text)
                t.column("iCalUID", .text)
                t.column("subject", .text).notNull().defaults(to: "")
                t.column("bodyPreview", .text)
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime).notNull()
                t.column("isAllDay", .boolean).notNull().defaults(to: false)
                t.column("organizerEmail", .text)
                t.column("organizerName", .text)
                t.column("rsvpStatus", .text).notNull().defaults(to: "none")
                t.column("isOnlineMeeting", .boolean).notNull().defaults(to: false)
                t.column("onlineMeetingProvider", .text)
                t.column("attendeeDomainsCSV", .text)
                t.column("location", .text)
                t.column("verifiedAttended", .boolean).notNull().defaults(to: false)
                t.column("customerID", .text)
                t.column("projectID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_calendar_events_startAt", on: "calendar_events", columns: ["startAt"])
        }
        migrator.registerMigration("v5_claude_sessions") { db in
            try db.create(table: "claude_sessions") { t in
                t.primaryKey("id", .text)
                t.column("cwd", .text)
                t.column("transcriptPath", .text)
                t.column("gitRepoPath", .text)
                t.column("gitRemoteURL", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("promptCount", .integer).notNull().defaults(to: 0)
                t.column("customerID", .text)
                t.column("projectID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_claude_sessions_startedAt", on: "claude_sessions", columns: ["startedAt"])
        }
        migrator.registerMigration("v6_claude_session_activity") { db in
            try db.alter(table: "claude_sessions") { t in
                t.add(column: "lastActivityAt", .datetime)
                t.add(column: "activeSeconds", .double).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v7_sample_overrides") { db in
            try db.alter(table: "activity_samples") { t in
                t.add(column: "customerID", .text)
                t.add(column: "projectID", .text)
            }
        }
        migrator.registerMigration("v8_mic_sessions") { db in
            try db.create(table: "mic_sessions") { t in
                t.primaryKey("id", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("voipAppsCSV", .text)
                t.column("participant", .text)
                t.column("customerID", .text)
                t.column("projectID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_mic_sessions_startedAt", on: "mic_sessions", columns: ["startedAt"])
        }
        migrator.registerMigration("v9_hidden_signals") { db in
            try db.create(table: "hidden_signals") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("hiddenAt", .datetime).notNull()
                t.uniqueKey(["kind", "value"])
            }
            try db.create(index: "idx_hidden_signals_kind", on: "hidden_signals", columns: ["kind"])
        }
        migrator.registerMigration("v10_claude_active_deltas") { db in
            try db.create(table: "claude_active_deltas") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionID", .text).notNull()
                t.column("occurredAt", .datetime).notNull()
                t.column("gainedSeconds", .double).notNull()
            }
            try db.create(index: "idx_claude_active_deltas_occurredAt",
                          on: "claude_active_deltas", columns: ["occurredAt"])
            try db.create(index: "idx_claude_active_deltas_sessionID",
                          on: "claude_active_deltas", columns: ["sessionID"])
        }
        // Adds externalSource/externalID/externalSyncedAt for Command Center sync,
        // and rebuilds `customers` to drop the inline UNIQUE(name) constraint —
        // CC clients can legitimately share names with local customers, and a
        // declared UNIQUE in the table body cannot be dropped via ALTER TABLE.
        migrator.registerMigration("v11_external_source") { db in
            // ---- customers: rebuild to drop UNIQUE(name) + add external columns
            try db.create(table: "customers_new") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("externalSource", .text)
                t.column("externalID", .text)
                t.column("externalSyncedAt", .datetime)
            }
            try db.execute(sql: """
                INSERT INTO customers_new (id, name, color, createdAt)
                SELECT id, name, color, createdAt FROM customers
                """)
            try db.drop(table: "customers")
            try db.rename(table: "customers_new", to: "customers")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_customers_external
                ON customers(externalSource, externalID)
                WHERE externalSource IS NOT NULL
                """)

            // ---- projects: nullable columns can be added in place
            try db.alter(table: "projects") { t in
                t.add(column: "externalSource", .text)
                t.add(column: "externalID", .text)
                t.add(column: "externalSyncedAt", .datetime)
                t.add(column: "engagementType", .text)
                t.add(column: "externalColor", .text)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_projects_external
                ON projects(externalSource, externalID)
                WHERE externalSource IS NOT NULL
                """)
        }
        // Series-aware meeting attribution. Drops the old auto-by-attendee-domain
        // path in favour of explicit per-event / per-series attribution + ignore.
        migrator.registerMigration("v12_meeting_series_and_ignore") { db in
            try db.alter(table: "calendar_events") { t in
                t.add(column: "eventType", .text)
                t.add(column: "seriesMasterID", .text)
                t.add(column: "isIgnored", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "idx_calendar_events_seriesMasterID",
                on: "calendar_events",
                columns: ["seriesMasterID"]
            )
            try db.create(table: "meeting_series_attributions") { t in
                t.primaryKey("seriesMasterID", .text)
                t.column("customerID", .text)
                t.column("projectID", .text)
                t.column("isIgnored", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }
            // Remove rows from the discontinued .emailDomain rule kind.
            try db.execute(sql: "DELETE FROM rules WHERE kind = 'emailDomain'")
        }
        try migrator.migrate(dbQueue)
    }

    func insert(_ sample: ActivitySample) throws -> ActivitySample {
        try dbQueue.write { db in
            var s = sample
            try s.insert(db)
            return s
        }
    }

    func recentSamples(limit: Int = 200) throws -> [ActivitySample] {
        try dbQueue.read { db in
            try ActivitySample
                .order(ActivitySample.Columns.capturedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func sampleCount() throws -> Int {
        try dbQueue.read { db in
            try ActivitySample.fetchCount(db)
        }
    }

    /// Sets the manual attribution override on a range of sample IDs.
    /// Pass nil to clear.
    func setSampleAttribution(sampleIDs: [Int64], customerID: String?, projectID: String?) throws {
        guard !sampleIDs.isEmpty else { return }
        _ = try dbQueue.write { db in
            try ActivitySample
                .filter(sampleIDs.contains(ActivitySample.Columns.id))
                .updateAll(db,
                           ActivitySample.Columns.customerID.set(to: customerID),
                           ActivitySample.Columns.projectID.set(to: projectID))
        }
    }

    func setCalendarEventAttribution(eventID: String, customerID: String?, projectID: String?) throws {
        _ = try dbQueue.write { db in
            try CalendarEvent
                .filter(CalendarEvent.Columns.id == eventID)
                .updateAll(db,
                           CalendarEvent.Columns.customerID.set(to: customerID),
                           CalendarEvent.Columns.projectID.set(to: projectID))
        }
    }

    func setClaudeSessionAttribution(sessionID: String, customerID: String?, projectID: String?) throws {
        _ = try dbQueue.write { db in
            try ClaudeSession
                .filter(ClaudeSession.Columns.id == sessionID)
                .updateAll(db,
                           ClaudeSession.Columns.customerID.set(to: customerID),
                           ClaudeSession.Columns.projectID.set(to: projectID))
        }
    }

    // MARK: - Mic sessions

    /// Inserts a new open mic session (endedAt = nil). Returns the new id.
    @discardableResult
    func startMicSession(at startedAt: Date, voipApps: [String]) throws -> String {
        let id = UUID().uuidString
        let csv = voipApps.isEmpty ? nil : voipApps.joined(separator: ",")
        let now = Date()
        var session = MicSession(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            voipAppsCSV: csv,
            participant: nil,
            customerID: nil,
            projectID: nil,
            createdAt: now,
            updatedAt: now
        )
        try dbQueue.write { db in
            try session.insert(db)
        }
        return id
    }

    func endMicSession(id: String, endedAt: Date, participant: String?, voipApps: [String]?) throws {
        _ = try dbQueue.write { db in
            if let voipApps {
                let csv = voipApps.isEmpty ? nil : voipApps.joined(separator: ",")
                try MicSession
                    .filter(MicSession.Columns.id == id)
                    .updateAll(db,
                               MicSession.Columns.endedAt.set(to: endedAt),
                               MicSession.Columns.participant.set(to: participant),
                               MicSession.Columns.voipAppsCSV.set(to: csv),
                               MicSession.Columns.updatedAt.set(to: Date()))
            } else {
                try MicSession
                    .filter(MicSession.Columns.id == id)
                    .updateAll(db,
                               MicSession.Columns.endedAt.set(to: endedAt),
                               MicSession.Columns.participant.set(to: participant),
                               MicSession.Columns.updatedAt.set(to: Date()))
            }
        }
    }

    /// Closes any sessions left open from a previous run (app crash, force-quit).
    /// Sets their endedAt to startedAt + 1s so they don't show as ongoing forever.
    func closeOrphanedMicSessions(currentlyRunningSessionID: String?) throws {
        try dbQueue.write { db in
            let openSessions = try MicSession
                .filter(MicSession.Columns.endedAt == nil)
                .fetchAll(db)
            for var s in openSessions {
                if let current = currentlyRunningSessionID, s.id == current { continue }
                s.endedAt = s.startedAt.addingTimeInterval(1)
                s.updatedAt = Date()
                try s.update(db)
            }
        }
    }

    func micSessions(in interval: DateInterval, minDurationSeconds: Double = 60) throws -> [MicSession] {
        try dbQueue.read { db in
            try MicSession
                .filter(MicSession.Columns.startedAt >= interval.start
                        && MicSession.Columns.startedAt < interval.end)
                .order(MicSession.Columns.startedAt.desc)
                .fetchAll(db)
                .filter { ($0.durationSeconds ?? 0) >= minDurationSeconds || $0.endedAt == nil }
        }
    }

    func setMicSessionAttribution(id: String, customerID: String?, projectID: String?) throws {
        _ = try dbQueue.write { db in
            try MicSession
                .filter(MicSession.Columns.id == id)
                .updateAll(db,
                           MicSession.Columns.customerID.set(to: customerID),
                           MicSession.Columns.projectID.set(to: projectID),
                           MicSession.Columns.updatedAt.set(to: Date()))
        }
    }

    /// Find frontmost-app + window-title samples that overlap a time window —
    /// used to enrich a mic session with a participant guess from Teams titles.
    func samplesOverlapping(start: Date, end: Date) throws -> [ActivitySample] {
        try dbQueue.read { db in
            try ActivitySample
                .filter(ActivitySample.Columns.capturedAt >= start
                        && ActivitySample.Columns.capturedAt <= end)
                .order(ActivitySample.Columns.capturedAt.asc)
                .fetchAll(db)
        }
    }

    func samples(in interval: DateInterval) throws -> [ActivitySample] {
        try dbQueue.read { db in
            try ActivitySample
                .filter(ActivitySample.Columns.capturedAt >= interval.start
                        && ActivitySample.Columns.capturedAt < interval.end)
                .order(ActivitySample.Columns.capturedAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Customers

    /// Active customers (locals + non-archived externals). Use this in pickers.
    func allCustomers() throws -> [Customer] {
        try dbQueue.read { db in
            try Customer
                .filter(Customer.Columns.externalSource == nil
                        || Customer.Columns.externalSource == ExternalSource.commandCenter.rawValue)
                .order(Customer.Columns.name.asc)
                .fetchAll(db)
        }
    }

    /// Every customer row regardless of archive status. Use for reporting,
    /// where historical attributions to a now-archived customer must still resolve.
    func allCustomersIncludingArchived() throws -> [Customer] {
        try dbQueue.read { db in
            try Customer.order(Customer.Columns.name.asc).fetchAll(db)
        }
    }

    func upsert(_ customer: Customer) throws {
        try dbQueue.write { db in
            var c = customer
            try c.upsert(db)
        }
    }

    func deleteCustomer(id: String) throws {
        _ = try dbQueue.write { db in
            try Customer.deleteOne(db, key: id)
        }
    }

    func customer(externalSource: ExternalSource, externalID: String) throws -> Customer? {
        try dbQueue.read { db in
            try Customer
                .filter(Customer.Columns.externalSource == externalSource.rawValue
                        && Customer.Columns.externalID == externalID)
                .fetchOne(db)
        }
    }

    /// Customers that came from `source` and are not in `keepingExternalIDs` get
    /// flipped to the archived flavor. Returns the count archived.
    @discardableResult
    func archiveMissingCustomers(source: ExternalSource, keepingExternalIDs: Set<String>) throws -> Int {
        try dbQueue.write { db in
            try Customer
                .filter(Customer.Columns.externalSource == source.rawValue
                        && !keepingExternalIDs.contains(Customer.Columns.externalID))
                .updateAll(db, Customer.Columns.externalSource.set(to: ExternalSource.commandCenterArchived.rawValue))
        }
    }

    // MARK: - Rules

    func allRules() throws -> [Rule] {
        try dbQueue.read { db in
            try Rule.order(Rule.Columns.priority.desc).fetchAll(db)
        }
    }

    func rules(forCustomer customerID: String) throws -> [Rule] {
        try dbQueue.read { db in
            try Rule
                .filter(Rule.Columns.customerID == customerID)
                .order(Rule.Columns.priority.desc, Rule.Columns.kind.asc)
                .fetchAll(db)
        }
    }

    func upsert(_ rule: Rule) throws {
        try dbQueue.write { db in
            var r = rule
            try r.upsert(db)
        }
    }

    func deleteRule(id: String) throws {
        _ = try dbQueue.write { db in
            try Rule.deleteOne(db, key: id)
        }
    }

    // MARK: - Projects

    /// Active projects only. Includes locals + non-archived externals.
    func allProjects() throws -> [Project] {
        try dbQueue.read { db in
            try Project
                .filter(Project.Columns.externalSource == nil
                        || Project.Columns.externalSource == ExternalSource.commandCenter.rawValue)
                .order(Project.Columns.name.asc)
                .fetchAll(db)
        }
    }

    func allProjectsIncludingArchived() throws -> [Project] {
        try dbQueue.read { db in
            try Project.order(Project.Columns.name.asc).fetchAll(db)
        }
    }

    func projects(forCustomer customerID: String) throws -> [Project] {
        try dbQueue.read { db in
            try Project
                .filter(Project.Columns.customerID == customerID
                        && (Project.Columns.externalSource == nil
                            || Project.Columns.externalSource == ExternalSource.commandCenter.rawValue))
                .order(Project.Columns.name.asc)
                .fetchAll(db)
        }
    }

    func upsert(_ project: Project) throws {
        try dbQueue.write { db in
            var p = project
            try p.upsert(db)
        }
    }

    func deleteProject(id: String) throws {
        _ = try dbQueue.write { db in
            try Project.deleteOne(db, key: id)
        }
    }

    func project(externalSource: ExternalSource, externalID: String) throws -> Project? {
        try dbQueue.read { db in
            try Project
                .filter(Project.Columns.externalSource == externalSource.rawValue
                        && Project.Columns.externalID == externalID)
                .fetchOne(db)
        }
    }

    @discardableResult
    func archiveMissingProjects(source: ExternalSource, keepingExternalIDs: Set<String>) throws -> Int {
        try dbQueue.write { db in
            try Project
                .filter(Project.Columns.externalSource == source.rawValue
                        && !keepingExternalIDs.contains(Project.Columns.externalID))
                .updateAll(db, Project.Columns.externalSource.set(to: ExternalSource.commandCenterArchived.rawValue))
        }
    }

    func externalCustomerCount(source: ExternalSource) throws -> Int {
        try dbQueue.read { db in
            try Customer
                .filter(Customer.Columns.externalSource == source.rawValue)
                .fetchCount(db)
        }
    }

    func externalProjectCount(source: ExternalSource) throws -> Int {
        try dbQueue.read { db in
            try Project
                .filter(Project.Columns.externalSource == source.rawValue)
                .fetchCount(db)
        }
    }

    // MARK: - Hidden signals

    func allHiddenSignals() throws -> [HiddenSignal] {
        try dbQueue.read { db in
            try HiddenSignal.order(HiddenSignal.Columns.hiddenAt.desc).fetchAll(db)
        }
    }

    /// Hide an app bundle ID or browser host. No-op if already hidden.
    func hideSignal(kind: HiddenSignal.Kind, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            let existing = try HiddenSignal
                .filter(HiddenSignal.Columns.kind == kind.rawValue
                        && HiddenSignal.Columns.value == trimmed)
                .fetchOne(db)
            if existing != nil { return }
            var record = HiddenSignal(
                id: UUID().uuidString,
                kind: kind,
                value: trimmed,
                hiddenAt: Date()
            )
            try record.insert(db)
        }
    }

    func unhide(id: String) throws {
        _ = try dbQueue.write { db in
            try HiddenSignal.deleteOne(db, key: id)
        }
    }

    // MARK: - Calendar events

    func upsertEvents(_ events: [CalendarEvent]) throws {
        try dbQueue.write { db in
            for event in events {
                var e = event
                try e.upsert(db)
            }
        }
    }

    func calendarEvents(in interval: DateInterval) throws -> [CalendarEvent] {
        try dbQueue.read { db in
            try CalendarEvent
                .filter(CalendarEvent.Columns.startAt >= interval.start
                        && CalendarEvent.Columns.startAt < interval.end)
                .order(CalendarEvent.Columns.startAt.asc)
                .fetchAll(db)
        }
    }

    func recentCalendarEvents(limit: Int = 50) throws -> [CalendarEvent] {
        try dbQueue.read { db in
            try CalendarEvent
                .order(CalendarEvent.Columns.startAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func calendarEventCount() throws -> Int {
        try dbQueue.read { db in
            try CalendarEvent.fetchCount(db)
        }
    }

    // MARK: - Claude sessions

    func upsertSession(_ session: ClaudeSession) throws {
        try dbQueue.write { db in
            var s = session
            try s.upsert(db)
        }
    }

    func session(id: String) throws -> ClaudeSession? {
        try dbQueue.read { db in
            try ClaudeSession.fetchOne(db, key: id)
        }
    }

    func recentSessions(limit: Int = 50) throws -> [ClaudeSession] {
        try dbQueue.read { db in
            try ClaudeSession
                .order(ClaudeSession.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func sessionCount() throws -> Int {
        try dbQueue.read { db in
            try ClaudeSession.fetchCount(db)
        }
    }

    func sessions(in interval: DateInterval) throws -> [ClaudeSession] {
        try dbQueue.read { db in
            try ClaudeSession
                .filter(ClaudeSession.Columns.startedAt < interval.end
                        && (ClaudeSession.Columns.endedAt == nil
                            || ClaudeSession.Columns.endedAt > interval.start))
                .order(ClaudeSession.Columns.startedAt.asc)
                .fetchAll(db)
        }
    }

    func openSessions() throws -> [ClaudeSession] {
        try dbQueue.read { db in
            try ClaudeSession
                .filter(ClaudeSession.Columns.endedAt == nil)
                .fetchAll(db)
        }
    }

    struct ClaudeActiveDelta: Codable, FetchableRecord {
        var sessionID: String
        var occurredAt: Date
        var gainedSeconds: Double
    }

    func insertClaudeActiveDelta(sessionID: String, occurredAt: Date, gainedSeconds: Double) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO claude_active_deltas (sessionID, occurredAt, gainedSeconds)
                VALUES (?, ?, ?)
                """, arguments: [sessionID, occurredAt, gainedSeconds])
        }
    }

    func claudeActiveDeltas(in interval: DateInterval) throws -> [ClaudeActiveDelta] {
        try dbQueue.read { db in
            try ClaudeActiveDelta.fetchAll(db, sql: """
                SELECT sessionID, occurredAt, gainedSeconds
                FROM claude_active_deltas
                WHERE occurredAt >= ? AND occurredAt < ?
                ORDER BY occurredAt
                """, arguments: [interval.start, interval.end])
        }
    }

    /// Per git-repo-slug time totals from Claude Code sessions whose start falls
    /// in the interval. Uses each session's amortized active seconds.
    func sessionRepoAggregates(in interval: DateInterval, idleThresholdSeconds: TimeInterval) throws -> [SignalAggregate] {
        let sessions = try self.sessions(in: interval)
        var totals: [String: Double] = [:]
        for session in sessions {
            guard let url = session.gitRemoteURL,
                  let slug = RuleMatcher.gitSlug(fromRemote: url) else { continue }
            let active = session.amortizedActiveSeconds(idleThresholdSeconds: idleThresholdSeconds)
            guard active > 0 else { continue }
            totals[slug, default: 0] += active
        }
        return totals.map {
            SignalAggregate(kind: .gitRepoSlug, value: $0.key, totalSeconds: $0.value)
        }
    }

    func deleteCalendarEvent(id: String) throws {
        _ = try dbQueue.write { db in
            try CalendarEvent.deleteOne(db, key: id)
        }
    }

    // MARK: - Meeting attribution

    func setCalendarEventIgnored(eventID: String, isIgnored: Bool) throws {
        _ = try dbQueue.write { db in
            try CalendarEvent
                .filter(CalendarEvent.Columns.id == eventID)
                .updateAll(db, CalendarEvent.Columns.isIgnored.set(to: isIgnored))
        }
    }

    func allMeetingSeriesAttributions() throws -> [MeetingSeriesAttribution] {
        try dbQueue.read { db in
            try MeetingSeriesAttribution.fetchAll(db)
        }
    }

    func meetingSeriesAttribution(seriesID: String) throws -> MeetingSeriesAttribution? {
        try dbQueue.read { db in
            try MeetingSeriesAttribution.fetchOne(db, key: seriesID)
        }
    }

    /// Upsert (or delete-if-empty) the row for a series.
    /// Passing `customerID = nil`, `projectID = nil`, and `isIgnored = false`
    /// deletes the row — i.e. the series falls back to "unattributed".
    func setMeetingSeriesAttribution(seriesID: String,
                                     customerID: String?,
                                     projectID: String?,
                                     isIgnored: Bool) throws {
        try dbQueue.write { db in
            if customerID == nil && projectID == nil && !isIgnored {
                try MeetingSeriesAttribution.deleteOne(db, key: seriesID)
                return
            }
            var record = MeetingSeriesAttribution(
                seriesMasterID: seriesID,
                customerID: customerID,
                projectID: projectID,
                isIgnored: isIgnored,
                updatedAt: Date()
            )
            try record.upsert(db)
        }
    }

    /// Aggregates suitable for the Discover "Recurring series" list.
    struct MeetingSeriesAggregate: Identifiable, Hashable {
        let seriesMasterID: String
        let sampleSubject: String
        let occurrenceCount: Int
        let totalSeconds: Double
        let firstStartAt: Date
        let lastStartAt: Date
        var id: String { seriesMasterID }
    }

    /// Series with at least one occurrence in the interval, ignoring per-event
    /// `isIgnored` flags (we leave it to the caller to filter out ignored
    /// series via `meetingSeriesAttribution`).
    func meetingSeriesAggregates(in interval: DateInterval) throws -> [MeetingSeriesAggregate] {
        try dbQueue.read { db in
            let events = try CalendarEvent
                .filter(CalendarEvent.Columns.startAt >= interval.start
                        && CalendarEvent.Columns.startAt < interval.end
                        && CalendarEvent.Columns.seriesMasterID != nil)
                .order(CalendarEvent.Columns.startAt.asc)
                .fetchAll(db)

            var byID: [String: [CalendarEvent]] = [:]
            for e in events {
                guard let sid = e.seriesMasterID else { continue }
                byID[sid, default: []].append(e)
            }
            return byID.compactMap { (sid, group) -> MeetingSeriesAggregate? in
                guard let first = group.first, let last = group.last else { return nil }
                // Pick the most-frequent subject so a series that gets renamed
                // on one occurrence still surfaces under its canonical name.
                var counts: [String: Int] = [:]
                for e in group { counts[e.subject, default: 0] += 1 }
                let subject = counts.max { $0.value < $1.value }?.key ?? first.subject
                let total = group.reduce(0.0) { $0 + max(0, $1.endAt.timeIntervalSince($1.startAt)) }
                return MeetingSeriesAggregate(
                    seriesMasterID: sid,
                    sampleSubject: subject.isEmpty ? "(no subject)" : subject,
                    occurrenceCount: group.count,
                    totalSeconds: total,
                    firstStartAt: first.startAt,
                    lastStartAt: last.startAt
                )
            }
            .sorted { $0.totalSeconds > $1.totalSeconds }
        }
    }

    /// One-off meetings: events that are not part of a series. Ignored events
    /// are filtered out at the database level — Discover surfaces them under
    /// the Ignored list instead.
    func oneOffMeetingAggregates(in interval: DateInterval) throws -> [CalendarEvent] {
        try dbQueue.read { db in
            try CalendarEvent
                .filter(CalendarEvent.Columns.startAt >= interval.start
                        && CalendarEvent.Columns.startAt < interval.end
                        && CalendarEvent.Columns.seriesMasterID == nil
                        && CalendarEvent.Columns.isIgnored == false)
                .order(CalendarEvent.Columns.startAt.desc)
                .fetchAll(db)
        }
    }

    /// Ignored items in the range — both per-event ignores and series-level
    /// ignores. Series rows are exposed as their seriesMasterID; the caller
    /// joins to `meetingSeriesAggregates` for a friendly label.
    struct IgnoredMeetingAggregate: Identifiable, Hashable {
        enum Scope: Hashable { case event, series }
        let scope: Scope
        let id: String              // event id or seriesMasterID
        let label: String           // event subject or series subject
        let totalSeconds: Double    // event duration or sum of in-range occurrences
        let occurrenceCount: Int?   // series only
    }

    func ignoredMeetingAggregates(in interval: DateInterval) throws -> [IgnoredMeetingAggregate] {
        try dbQueue.read { db in
            // Per-event ignores within range.
            let ignoredEvents = try CalendarEvent
                .filter(CalendarEvent.Columns.startAt >= interval.start
                        && CalendarEvent.Columns.startAt < interval.end
                        && CalendarEvent.Columns.isIgnored == true)
                .order(CalendarEvent.Columns.startAt.desc)
                .fetchAll(db)

            var rows: [IgnoredMeetingAggregate] = ignoredEvents.map { e in
                IgnoredMeetingAggregate(
                    scope: .event,
                    id: e.id,
                    label: e.subject.isEmpty ? "(no subject)" : e.subject,
                    totalSeconds: max(0, e.endAt.timeIntervalSince(e.startAt)),
                    occurrenceCount: nil
                )
            }

            // Series ignores: every series that has a stored attribution row
            // with isIgnored=true. We still surface them even when no
            // occurrence falls in range — the user can un-ignore from there.
            let ignoredSeries = try MeetingSeriesAttribution
                .filter(MeetingSeriesAttribution.Columns.isIgnored == true)
                .fetchAll(db)

            for series in ignoredSeries {
                let occurrences = try CalendarEvent
                    .filter(CalendarEvent.Columns.seriesMasterID == series.seriesMasterID
                            && CalendarEvent.Columns.startAt >= interval.start
                            && CalendarEvent.Columns.startAt < interval.end)
                    .fetchAll(db)
                let firstSubject = occurrences.first?.subject ?? ""
                let label = firstSubject.isEmpty ? "(no subject)" : firstSubject
                let total = occurrences.reduce(0.0) { $0 + max(0, $1.endAt.timeIntervalSince($1.startAt)) }
                rows.append(IgnoredMeetingAggregate(
                    scope: .series,
                    id: series.seriesMasterID,
                    label: label,
                    totalSeconds: total,
                    occurrenceCount: occurrences.count
                ))
            }
            return rows
        }
    }

    // MARK: - Local entity creation

    /// Color palette used for newly-created local customers. Picked round-robin
    /// from the count of existing customers so the first few are visually distinct.
    private static let localCustomerPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444",
        "#8B5CF6", "#EC4899", "#14B8A6"
    ]

    func createLocalCustomer(name: String) throws -> Customer {
        let count = try dbQueue.read { db in try Customer.fetchCount(db) }
        let color = Self.localCustomerPalette[count % Self.localCustomerPalette.count]
        let c = Customer(id: UUID().uuidString, name: name, color: color, createdAt: Date())
        try upsert(c)
        return c
    }

    func createLocalProject(customerID: String, name: String) throws -> Project {
        let p = Project(id: UUID().uuidString, customerID: customerID, name: name, color: nil, createdAt: Date())
        try upsert(p)
        return p
    }

    // MARK: - Aggregations for Discover

    struct SignalAggregate: Identifiable, Hashable {
        enum Kind: String, Hashable { case gitRepoSlug, urlHost, urlPath, appBundleID }
        let kind: Kind
        let value: String      // raw value (e.g. owner/repo, host, bundle id, attendee domain)
        let totalSeconds: Double
        var id: String { "\(kind.rawValue):\(value)" }
    }

    /// Aggregates non-idle activity by (signal kind, value) over the date range.
    func signalAggregates(in interval: DateInterval, sampleIntervalSeconds: Int) throws -> [SignalAggregate] {
        try dbQueue.read { db in
            let startISO = ActivitySample.Columns.capturedAt
            let secs = Double(sampleIntervalSeconds)

            let baseFilter = startISO >= interval.start
                && startISO < interval.end
                && ActivitySample.Columns.isIdle == false

            // Git: aggregate by gitRemoteURL (we'll convert to slug after fetch).
            let gitRows: [(String, Int)] = try ActivitySample
                .filter(baseFilter && Column("gitRemoteURL") != nil)
                .select(Column("gitRemoteURL"), count(Column("id")), as: Row.self)
                .group(Column("gitRemoteURL"))
                .fetchAll(db)
                .compactMap { row in
                    guard let url: String = row[0], let n: Int = row[1] else { return nil }
                    return (url, n)
                }
            let gitItems: [SignalAggregate] = gitRows.compactMap { (url, count) in
                guard let slug = RuleMatcher.gitSlug(fromRemote: url) else { return nil }
                return SignalAggregate(kind: .gitRepoSlug, value: slug,
                                       totalSeconds: Double(count) * secs)
            }
            // Merge duplicates that resolved to the same slug.
            let mergedGit = Dictionary(grouping: gitItems, by: { $0.value })
                .map { (slug, group) in
                    SignalAggregate(kind: .gitRepoSlug, value: slug,
                                    totalSeconds: group.reduce(0) { $0 + $1.totalSeconds })
                }

            // URL hosts.
            let hostRows: [(String, Int)] = try ActivitySample
                .filter(baseFilter && Column("chromeHost") != nil)
                .select(Column("chromeHost"), count(Column("id")), as: Row.self)
                .group(Column("chromeHost"))
                .fetchAll(db)
                .compactMap { row in
                    guard let host: String = row[0], let n: Int = row[1] else { return nil }
                    return (host, n)
                }
            let hostItems = hostRows.map {
                SignalAggregate(kind: .urlHost, value: $0.0, totalSeconds: Double($0.1) * secs)
            }

            // Apps.
            let appRows: [(String, Int)] = try ActivitySample
                .filter(baseFilter && Column("appBundleID") != nil)
                .select(Column("appBundleID"), count(Column("id")), as: Row.self)
                .group(Column("appBundleID"))
                .fetchAll(db)
                .compactMap { row in
                    guard let id: String = row[0], let n: Int = row[1] else { return nil }
                    return (id, n)
                }
            let appItems = appRows.map {
                SignalAggregate(kind: .appBundleID, value: $0.0, totalSeconds: Double($0.1) * secs)
            }

            return (mergedGit + hostItems + appItems).sorted { $0.totalSeconds > $1.totalSeconds }
        }
    }

    // MARK: - Teams sessions

    struct TeamsSession: Identifiable, Hashable {
        let id: String
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Double
        let participant: String?
        let kind: Kind
        let sampleIDs: [Int64]
        let customerID: String?
        let projectID: String?

        enum Kind: Hashable { case call, chat, mixed }
    }

    /// Contiguous Teams foreground activity, segmented into sessions wherever
    /// there's a gap larger than ~2× the sample interval. Pure-chat sessions
    /// are flagged separately so the UI can distinguish chats from calls.
    func teamsSessions(in interval: DateInterval,
                       sampleIntervalSeconds: Int,
                       minDurationSeconds: Double = 180) throws -> [TeamsSession] {
        try dbQueue.read { db in
            let teamsBundles: [String] = ["com.microsoft.teams", "com.microsoft.teams2"]
            let samples = try ActivitySample
                .filter(ActivitySample.Columns.capturedAt >= interval.start
                        && ActivitySample.Columns.capturedAt < interval.end
                        && ActivitySample.Columns.isIdle == false
                        && teamsBundles.contains(ActivitySample.Columns.appBundleID))
                .order(ActivitySample.Columns.capturedAt.asc)
                .fetchAll(db)

            let gapThreshold = TimeInterval(sampleIntervalSeconds) * 2.5
            let secs = Double(sampleIntervalSeconds)

            var groups: [[ActivitySample]] = []
            var current: [ActivitySample] = []
            for s in samples {
                if let last = current.last,
                   s.capturedAt.timeIntervalSince(last.capturedAt) > gapThreshold {
                    groups.append(current)
                    current = []
                }
                current.append(s)
            }
            if !current.isEmpty { groups.append(current) }

            return groups.compactMap { group in
                guard let first = group.first, let last = group.last else { return nil }
                let started = first.capturedAt
                let ended = last.capturedAt.addingTimeInterval(secs)
                let duration = ended.timeIntervalSince(started)
                guard duration >= minDurationSeconds else { return nil }

                var hasChat = false
                var hasCall = false
                var participantCounts: [String: Int] = [:]
                for s in group {
                    guard let title = s.windowTitle else { continue }
                    let segments = title.split(separator: "|").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    let lowerFirst = segments.first?.lowercased() ?? ""
                    if lowerFirst == "chat" {
                        hasChat = true
                    } else if !segments.isEmpty {
                        hasCall = true
                    }
                    if let p = participant(fromTitleSegments: segments) {
                        participantCounts[p, default: 0] += 1
                    }
                }
                let kind: TeamsSession.Kind
                switch (hasCall, hasChat) {
                case (true, false): kind = .call
                case (false, true): kind = .chat
                case (true, true):  kind = .mixed
                default:            kind = .call
                }
                let participant = participantCounts
                    .max { $0.value < $1.value }
                    .map { $0.key }

                // Attribution is "set" only if every sample shares the same override.
                let customers = Set(group.map { $0.customerID })
                let projects = Set(group.map { $0.projectID })
                let customerID = customers.count == 1 ? group[0].customerID : nil
                let projectID = customers.count == 1 && projects.count == 1 ? group[0].projectID : nil

                let sampleIDs = group.compactMap { $0.id }
                let id = "\(Int(started.timeIntervalSince1970)):\(sampleIDs.first ?? 0)"

                return TeamsSession(
                    id: id,
                    startedAt: started,
                    endedAt: ended,
                    durationSeconds: duration,
                    participant: participant,
                    kind: kind,
                    sampleIDs: sampleIDs,
                    customerID: customerID,
                    projectID: projectID
                )
            }.sorted { $0.startedAt > $1.startedAt }
        }
    }

    /// Pulls the participant name out of a Teams window title's segments.
    /// Teams window titles look like:
    ///   "Chat | Some Person | Some Org | someone@example.com | Microsoft Teams"
    ///   "Some Person | Some Org | someone@example.com | Microsoft Teams"
    /// We drop "Chat", "Microsoft Teams", and any email-like segment, then take
    /// the first remaining piece.
    private func participant(fromTitleSegments segments: [String]) -> String? {
        for part in segments {
            let lower = part.lowercased()
            if lower == "chat" || lower == "microsoft teams" { continue }
            if part.contains("@") { continue }
            if part.isEmpty { continue }
            return part
        }
        return nil
    }

    /// URL-path breakdown for a single browser host over an interval. Aggregates
    /// chromeURL by `host[/seg1[/seg2]]` so e.g. github.com surfaces one row per
    /// `owner/repo`. Returned sorted descending; truncated to `limit`.
    func urlPathAggregates(forHost host: String,
                           in interval: DateInterval,
                           sampleIntervalSeconds: Int,
                           segments: Int = 2,
                           limit: Int = 8) throws -> [SignalAggregate] {
        try dbQueue.read { db in
            let startISO = ActivitySample.Columns.capturedAt
            let secs = Double(sampleIntervalSeconds)
            let urls: [String] = try ActivitySample
                .filter(startISO >= interval.start
                        && startISO < interval.end
                        && ActivitySample.Columns.isIdle == false
                        && Column("chromeHost") == host
                        && Column("chromeURL") != nil)
                .select(Column("chromeURL"), as: String.self)
                .fetchAll(db)
            var counts: [String: Int] = [:]
            for url in urls {
                guard let prefix = RuleMatcher.urlPathPrefix(url, segments: segments) else { continue }
                counts[prefix, default: 0] += 1
            }
            let aggregates = counts.map {
                SignalAggregate(kind: .urlPath, value: $0.key, totalSeconds: Double($0.value) * secs)
            }
            return Array(aggregates.sorted { $0.totalSeconds > $1.totalSeconds }.prefix(limit))
        }
    }
}
