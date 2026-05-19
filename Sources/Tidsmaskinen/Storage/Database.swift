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
        try dbQueue.write { db in
            try ActivitySample
                .filter(sampleIDs.contains(ActivitySample.Columns.id))
                .updateAll(db,
                           ActivitySample.Columns.customerID.set(to: customerID),
                           ActivitySample.Columns.projectID.set(to: projectID))
        }
    }

    func setCalendarEventAttribution(eventID: String, customerID: String?, projectID: String?) throws {
        try dbQueue.write { db in
            try CalendarEvent
                .filter(CalendarEvent.Columns.id == eventID)
                .updateAll(db,
                           CalendarEvent.Columns.customerID.set(to: customerID),
                           CalendarEvent.Columns.projectID.set(to: projectID))
        }
    }

    func setClaudeSessionAttribution(sessionID: String, customerID: String?, projectID: String?) throws {
        try dbQueue.write { db in
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

    func allCustomers() throws -> [Customer] {
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

    func allProjects() throws -> [Project] {
        try dbQueue.read { db in
            try Project.order(Project.Columns.name.asc).fetchAll(db)
        }
    }

    func projects(forCustomer customerID: String) throws -> [Project] {
        try dbQueue.read { db in
            try Project
                .filter(Project.Columns.customerID == customerID)
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

    /// Per attendee-domain time totals over an interval. Each event's duration
    /// is added to every distinct attendee domain on that event.
    func meetingDomainAggregates(in interval: DateInterval) throws -> [SignalAggregate] {
        let events = try calendarEvents(in: interval)
        var totals: [String: Double] = [:]
        for event in events {
            let duration = max(0, event.endAt.timeIntervalSince(event.startAt))
            guard duration > 0 else { continue }
            for domain in event.attendeeDomains {
                totals[domain, default: 0] += duration
            }
        }
        return totals
            .map { SignalAggregate(kind: .meetingDomain, value: $0.key, totalSeconds: $0.value) }
            .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    func deleteCalendarEvent(id: String) throws {
        _ = try dbQueue.write { db in
            try CalendarEvent.deleteOne(db, key: id)
        }
    }

    // MARK: - Aggregations for Discover

    struct SignalAggregate: Identifiable, Hashable {
        enum Kind: String, Hashable { case gitRepoSlug, urlHost, urlPath, appBundleID, meetingDomain }
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
    ///   "Chat | Jonas Roslin | Forefront Group | niklas@forefront.se | Microsoft Teams"
    ///   "Jonas Roslin | Forefront Group | niklas@forefront.se | Microsoft Teams"
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
