import Foundation
import GRDB

// Which coding-agent session the user has in front of them.
//
// Claude desktop: its own log (`~/Library/Logs/Claude/main*.log`) writes
// `LocalSessions.setFocusedSession: sessionId=local_<uuid>` on every switch
// between Code sessions, and `sessionId=null` when the user leaves them (the
// Chat tab, settings). The local id maps to the CLI session id — the hook
// `session_id` and `claude_sessions.id` — through the desktop app's session
// file. The log keeps about three weeks, so every line is copied into
// `claude_focus_events` as it is written; that table is the focus history.
//
// Codex: the window title is the thread's name, looked up in Codex's own
// `threads` table. A title shared by two threads resolves to nothing.
//
// Both sources are undocumented app internals. Nothing here guesses: a sample
// whose session can't be read keeps no session.

/// One line of Claude desktop's log about which Code session is in front.
struct ClaudeFocusEvent: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A switch: `localSessionID` is the session now in front, or nil when
        /// no Code session is (Chat tab or another view).
        case focus
        /// Claude started. Until its next focus line nothing is known.
        case launch
    }

    var occurredAt: Date
    /// Order among lines that share a second, in file order. A switch logs
    /// `null` and then the new id within the same second.
    var seq: Int
    var kind: Kind
    var localSessionID: String?
    /// Filled from the desktop app's session file once known.
    var cliSessionID: String?

    static let databaseTableName = "claude_focus_events"
}

enum ClaudeFocusLog {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Claude", isDirectory: true)
    }

    private static let focusMarker = "LocalSessions.setFocusedSession: sessionId="
    private static let launchMarker = "[startup-perf] main window created"

    /// `main.log` is current; `main1.log`, `main2.log`, … are older rotations.
    /// Returned oldest first so events come out in time order.
    static func logFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let ranked: [(Int, String)] = names.compactMap { name in
            guard name.hasPrefix("main"), name.hasSuffix(".log") else { return nil }
            let middle = name.dropFirst(4).dropLast(4)
            if middle.isEmpty { return (0, name) }
            guard let n = Int(middle) else { return nil }
            return (n, name)
        }
        return ranked.sorted { $0.0 > $1.0 }.map { directory.appendingPathComponent($0.1) }
    }

    /// One parsed line, before it is numbered within its second.
    struct Line: Equatable {
        var occurredAt: Date
        var kind: ClaudeFocusEvent.Kind
        var localSessionID: String?
    }

    /// Lines start with `yyyy-MM-dd HH:mm:ss` in local time.
    static func parse(line: Substring, timeZone: TimeZone = .current) -> Line? {
        let kind: ClaudeFocusEvent.Kind
        var localID: String?
        if let r = line.range(of: focusMarker) {
            let value = line[r.upperBound...].prefix { !$0.isWhitespace }
            guard !value.isEmpty else { return nil }
            kind = .focus
            if value != "null" {
                guard value.hasPrefix("local_") else { return nil }
                localID = String(value)
            }
        } else if line.contains(launchMarker) {
            kind = .launch
        } else {
            return nil
        }
        guard line.count >= 19, let date = timestamp(line.prefix(19), timeZone: timeZone) else { return nil }
        return Line(occurredAt: date, kind: kind, localSessionID: localID)
    }

    private static func timestamp(_ s: Substring, timeZone: TimeZone) -> Date? {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
        guard parts.count == 6 else { return nil }
        let n = parts.compactMap { Int($0) }
        guard n.count == 6 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: n[0], month: n[1], day: n[2],
                                             hour: n[3], minute: n[4], second: n[5]))
    }

    /// Numbers lines that share a second, continuing from `counter` so a
    /// second split across two reads keeps its order.
    static func events(from lines: [Line], counter: inout (second: Date?, seq: Int)) -> [ClaudeFocusEvent] {
        lines.map { line in
            if line.occurredAt == counter.second {
                counter.seq += 1
            } else {
                counter = (line.occurredAt, 0)
            }
            return ClaudeFocusEvent(occurredAt: line.occurredAt, seq: counter.seq, kind: line.kind,
                                    localSessionID: line.localSessionID, cliSessionID: nil)
        }
    }

    /// Only the relevant lines of a chunk of log text.
    static func lines(in data: Data, timeZone: TimeZone = .current) -> [Line] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var out: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard raw.contains("setFocusedSession") || raw.contains("startup-perf") else { continue }
            if let line = parse(line: raw, timeZone: timeZone) { out.append(line) }
        }
        return out
    }
}

/// The resolved focus at one instant.
enum AgentFocus: Equatable {
    /// History doesn't reach this moment, or Claude had just started.
    case unknown
    /// Claude was in front of no Code session (Chat tab, settings).
    case noSession
    case session(localID: String)
}

/// Focus history as an ordered list, answering "what was in front at t".
struct ClaudeFocusTimeline {
    private let events: [ClaudeFocusEvent]

    init(events: [ClaudeFocusEvent]) {
        self.events = events.sorted { ($0.occurredAt, $0.seq) < ($1.occurredAt, $1.seq) }
    }

    var first: Date? { events.first?.occurredAt }

    func focus(at date: Date) -> AgentFocus {
        // Last event at or before `date`.
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].occurredAt <= date { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return .unknown }
        let e = events[lo - 1]
        switch e.kind {
        case .launch: return .unknown
        case .focus: return e.localSessionID.map { .session(localID: $0) } ?? .noSession
        }
    }
}

/// What the desktop app's session file says about one local session.
struct ClaudeDesktopSessionInfo: Equatable, Sendable {
    var localID: String
    var cliSessionID: String?
    var cwd: String?
    var title: String?
    var createdAt: Date?
}

/// Reads `~/Library/Application Support/Claude/claude-code-sessions/<a>/<b>/local_<id>.json`.
final class ClaudeDesktopSessions: @unchecked Sendable {
    private let root: URL
    private var directories: [URL] = []
    private var directoriesListedAt: Date?
    private var cache: [String: ClaudeDesktopSessionInfo] = [:]
    private let lock = NSLock()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)) {
        self.root = root
    }

    func info(localID: String) -> ClaudeDesktopSessionInfo? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[localID], hit.cliSessionID != nil { return hit }
        if let found = read(localID: localID, in: directories) { return found }
        // A session created since the last listing lives in a new folder.
        if directoriesListedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            listDirectories()
            return read(localID: localID, in: directories)
        }
        return cache[localID]
    }

    private func listDirectories() {
        let fm = FileManager.default
        var out: [URL] = []
        for a in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for b in (try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil)) ?? [] {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: b.path, isDirectory: &isDir), isDir.boolValue { out.append(b) }
            }
        }
        directories = out
        directoriesListedAt = Date()
    }

    private func read(localID: String, in dirs: [URL]) -> ClaudeDesktopSessionInfo? {
        for dir in dirs {
            let url = dir.appendingPathComponent("\(localID).json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let created = (obj["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let info = ClaudeDesktopSessionInfo(
                localID: localID,
                cliSessionID: (obj["cliSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                cwd: obj["cwd"] as? String,
                title: obj["title"] as? String,
                createdAt: created)
            cache[localID] = info
            return info
        }
        return nil
    }
}

/// Codex threads by window title, from Codex's own state database.
final class CodexThreads: @unchecked Sendable {
    static let bundleID = "com.openai.codex"

    struct Thread: Equatable, Sendable {
        var id: String
        var cwd: String?
        var gitOriginURL: String?
        var createdAt: Date? = nil
        var storedSessionID: String { CodingAgentProvider.codex.storedSessionID(id) }
    }

    private let directory: URL
    private var queue: DatabaseQueue?
    private var openedPath: String?
    private let lock = NSLock()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)) {
        self.directory = directory
    }

    /// The newest `state_<n>.sqlite`.
    private func databasePath() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let best = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let n = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (n, name)
        }.max { $0.0 < $1.0 }
        return best.map { directory.appendingPathComponent($0.1).path }
    }

    private func connection() -> DatabaseQueue? {
        guard let path = databasePath() else { return nil }
        if let queue, openedPath == path { return queue }
        var config = Configuration()
        config.readonly = true
        config.label = "codex-threads"
        queue = try? DatabaseQueue(path: path, configuration: config)
        openedPath = queue == nil ? nil : path
        return queue
    }

    /// The one user thread named `title`, or nil when none or several match.
    func thread(title: String) -> Thread? {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let db = connection() else { return nil }
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, cwd, git_origin_url FROM threads
                WHERE (thread_source IS NULL OR thread_source = 'user')
                  AND (trim(name) = ? OR trim(title) = ?)
                """, arguments: [key, key])
        }) ?? []
        let ids = Set(rows.map { $0["id"] as String })
        guard ids.count == 1, let row = rows.first else { return nil }
        // Optional column: a Codex version without it still resolves titles.
        let createdMs = try? db.read { db in
            try Int64.fetchOne(db, sql: "SELECT created_at_ms FROM threads WHERE id = ?", arguments: [row["id"] as String])
        }
        let created = (createdMs ?? nil).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return Thread(id: row["id"], cwd: row["cwd"], gitOriginURL: row["git_origin_url"], createdAt: created)
    }
}

/// Copies Claude's focus lines into the database as they are written and
/// answers which agent session a sample belongs to.
@MainActor
final class AgentFocusRecorder {
    private let database: AppDatabase
    private let logDirectory: URL
    let desktopSessions: ClaudeDesktopSessions
    let codexThreads: CodexThreads

    private var tailInode: UInt64?
    private var tailOffset: UInt64 = 0
    private var counter: (second: Date?, seq: Int) = (nil, 0)
    private var latest: ClaudeFocusEvent?
    /// True while all log files are being read off the main thread.
    private var isScanning = false
    /// When the log was last read without error; nil while it can't be read.
    private(set) var lastReadAt: Date?
    /// The newest focus line stored, for the health check.
    var latestEventAt: Date? { latest?.occurredAt }

    init(database: AppDatabase,
         logDirectory: URL = ClaudeFocusLog.defaultDirectory,
         desktopSessions: ClaudeDesktopSessions = ClaudeDesktopSessions(),
         codexThreads: CodexThreads = CodexThreads()) {
        self.database = database
        self.logDirectory = logDirectory
        self.desktopSessions = desktopSessions
        self.codexThreads = codexThreads
    }

    /// Reads every log file Claude still keeps, stores the lines not seen
    /// before, then gives stored samples the session history now shows.
    func start() {
        latest = try? database.latestClaudeFocusEvent()
        rescan(backfill: true)
    }

    private func rescan(backfill: Bool) {
        guard !isScanning else { return }
        isScanning = true
        let dir = logDirectory, db = database, desk = desktopSessions
        Task.detached(priority: .utility) {
            let readAt = Date()
            let scan = Self.readAll(directory: dir)
            let stored = (try? Self.store(scan.events, database: db, desktopSessions: desk)) != nil
            // History is complete up to when the files were read, no further.
            if stored, backfill { Self.backfillSamples(database: db, desktopSessions: desk, until: readAt) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if stored {
                    self.counter = scan.counter
                    self.tailInode = scan.tailInode
                    self.tailOffset = scan.tailOffset
                    self.lastReadAt = scan.tailInode == nil ? nil : readAt
                } else {
                    self.tailInode = nil   // next poll scans again
                    self.lastReadAt = nil
                }
                self.latest = (try? self.database.latestClaudeFocusEvent()) ?? self.latest
                self.isScanning = false
                // Samples taken while the scan ran got no session: catch up,
                // then give them the one the stored history now shows.
                self.poll()
                if let until = self.lastReadAt {
                    Task.detached(priority: .utility) {
                        Self.backfillSamples(database: db, desktopSessions: desk, until: until)
                    }
                }
            }
        }
    }

    private struct Scan: Sendable {
        var events: [ClaudeFocusEvent]
        var counter: (second: Date?, seq: Int)
        var tailInode: UInt64?
        var tailOffset: UInt64
    }

    nonisolated private static func readAll(directory: URL) -> Scan {
        var counter: (second: Date?, seq: Int) = (nil, 0)
        var events: [ClaudeFocusEvent] = []
        let files = ClaudeFocusLog.logFiles(in: directory)
        var inode: UInt64?, offset: UInt64 = 0
        for url in files {
            // Note the current file's size before reading so nothing appended
            // meanwhile is skipped: poll() resumes from this offset.
            let isCurrent = url.lastPathComponent == "main.log"
            if isCurrent { inode = Self.inode(of: url); offset = Self.size(of: url) ?? 0 }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            var data = (isCurrent ? try? handle.read(upToCount: Int(offset)) : try? handle.readToEnd()) ?? Data()
            try? handle.close()
            if isCurrent {
                // Stop at the last whole line; poll() reads the rest.
                let end = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
                data = Data(data[data.startIndex..<end])
                offset = UInt64(data.count)
            }
            events += ClaudeFocusLog.events(from: ClaudeFocusLog.lines(in: data), counter: &counter)
        }
        return Scan(events: events, counter: counter, tailInode: inode, tailOffset: offset)
    }

    /// Reads what was appended to `main.log` since the last call. After a
    /// rotation every file is read again; stored lines are ignored on repeat.
    func poll() {
        guard !isScanning else { return }
        let url = logDirectory.appendingPathComponent("main.log")
        guard let inode = Self.inode(of: url), let size = Self.size(of: url) else {
            lastReadAt = nil
            return
        }
        if inode != tailInode || size < tailOffset {
            rescan(backfill: false)
            return
        }
        guard size > tailOffset else { lastReadAt = Date(); return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { lastReadAt = nil; return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: tailOffset)
            let data = try handle.readToEnd() ?? Data()
            // Whole lines only: a partial last line is read again next time.
            guard let end = data.lastIndex(of: 0x0A) else { lastReadAt = Date(); return }
            let complete = Data(data[data.startIndex...end])
            var next = counter
            let events = ClaudeFocusLog.events(from: ClaudeFocusLog.lines(in: complete), counter: &next)
            // Only move past these lines once they are stored: the log rotates
            // away, so lines skipped on a failed write would be lost for good.
            try Self.store(events, database: database, desktopSessions: desktopSessions)
            counter = next
            tailOffset += UInt64(complete.count)
            if let last = events.last { latest = last }
            lastReadAt = Date()
        } catch {
            lastReadAt = nil
        }
    }

    nonisolated private static func store(_ events: [ClaudeFocusEvent], database: AppDatabase,
                                          desktopSessions: ClaudeDesktopSessions) throws {
        guard !events.isEmpty else { return }
        var cli: [String: String?] = [:]
        let resolved = events.map { e -> ClaudeFocusEvent in
            guard let local = e.localSessionID else { return e }
            if cli[local] == nil { cli[local] = .some(desktopSessions.info(localID: local)?.cliSessionID) }
            var r = e
            r.cliSessionID = cli[local] ?? nil
            return r
        }
        try database.insertClaudeFocusEvents(resolved)
    }

    /// The agent session in front for a sample being captured now.
    func sessionID(bundleID: String?, windowTitle: String?, claudeLaunchedAt: Date?) -> String? {
        switch bundleID {
        case ClaudeFocusLog.bundleID:
            poll()
            // Behind or unreadable: the stored history may miss a switch, so
            // this sample keeps no session (a backfill fills it in later).
            guard !isScanning, lastReadAt != nil,
                  let e = latest, e.kind == .focus, let local = e.localSessionID else { return nil }
            // A line from before Claude's current launch says nothing about now.
            if let launched = claudeLaunchedAt, e.occurredAt < launched.addingTimeInterval(-1) { return nil }
            guard let info = desktopSessions.info(localID: local),
                  let cli = e.cliSessionID ?? info.cliSessionID else { return nil }
            Self.ensureSessionRow(claude: info, cliSessionID: cli, database: database)
            return cli
        case CodexThreads.bundleID:
            guard let title = windowTitle, let thread = codexThreads.thread(title: title) else { return nil }
            Self.ensureSessionRow(codex: thread, database: database)
            return thread.storedSessionID
        default:
            return nil
        }
    }

    /// Sessions focused before their first hook (or with hooks off) still
    /// need a row so their repo and a manual pin can attribute them. The row
    /// is created closed; a later hook reopens it.
    nonisolated static func ensureSessionRow(claude info: ClaudeDesktopSessionInfo, cliSessionID: String,
                                             database: AppDatabase) {
        ensureSessionRow(id: cliSessionID, provider: .claude, cwd: info.cwd, remote: nil,
                         startedAt: info.createdAt, database: database)
    }

    nonisolated static func ensureSessionRow(codex thread: CodexThreads.Thread, database: AppDatabase) {
        ensureSessionRow(id: thread.storedSessionID, provider: .codex, cwd: thread.cwd,
                         remote: thread.gitOriginURL, startedAt: thread.createdAt, database: database)
    }

    nonisolated private static func ensureSessionRow(id: String, provider: CodingAgentProvider, cwd: String?,
                                                     remote: String?, startedAt: Date?, database: AppDatabase) {
        guard (try? database.session(id: id)) == nil else { return }   // cheap pre-check; the insert decides
        let root = cwd.flatMap { Probes.findGitRoot(near: $0) }
        let start = startedAt ?? Date()
        let row = ClaudeSession(
            id: id, cwd: cwd, transcriptPath: nil,
            gitRepoPath: root,
            gitRemoteURL: remote ?? root.flatMap { Probes.gitOriginURL(repoRoot: $0) },
            startedAt: start, endedAt: start, lastActivityAt: nil, activeSeconds: 0,
            promptCount: 0, customerID: nil, projectID: nil,
            createdAt: Date(), updatedAt: Date(), provider: provider)
        // Never over a row a hook created meanwhile. A placeholder has no
        // `lastActivityAt`; the hook ingester treats it as not yet started.
        try? database.insertSessionIfAbsent(row)
    }

    /// Gives stored Claude samples without a session the one history shows,
    /// up to `until` (how far the stored history is known to be complete).
    /// Codex samples are resolved only when captured: a thread renamed since
    /// could hand an old title to someone else's work.
    nonisolated static func backfillSamples(database: AppDatabase, desktopSessions: ClaudeDesktopSessions,
                                            until: Date) {
        guard let events = try? database.allClaudeFocusEvents(), !events.isEmpty,
              let first = events.first?.occurredAt,
              let samples = try? database.samplesWithoutAgentSession(bundleID: ClaudeFocusLog.bundleID, since: first)
        else { return }
        let timeline = ClaudeFocusTimeline(events: events)
        var cliByLocal: [String: String?] = [:]
        for e in events { if let l = e.localSessionID, let c = e.cliSessionID { cliByLocal[l] = c } }
        var ensured = Set<String>()
        var updates: [(Int64, String)] = []
        for s in samples where s.capturedAt <= until {
            guard let id = s.id, case .session(let local) = timeline.focus(at: s.capturedAt) else { continue }
            if cliByLocal[local] == nil {
                cliByLocal[local] = .some(desktopSessions.info(localID: local)?.cliSessionID)
            }
            guard let cli = cliByLocal[local] ?? nil else { continue }
            if ensured.insert(cli).inserted, let info = desktopSessions.info(localID: local) {
                ensureSessionRow(claude: info, cliSessionID: cli, database: database)
            }
            updates.append((id, cli))
        }
        try? database.setAgentSessions(updates)
    }

    nonisolated private static func inode(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    nonisolated private static func size(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}
