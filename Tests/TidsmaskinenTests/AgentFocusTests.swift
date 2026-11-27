import XCTest
import GRDB
@testable import Tidsmaskinen

/// Claude desktop's log lines become focus history; history and Codex thread
/// titles give samples their agent session, and nothing is guessed.
final class AgentFocusTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    private let idA = "local_6da844dd-8848-48e9-8289-c167a83c15e7"
    private let idB = "local_16a0e64d-d9b6-42b3-bc5f-df857a346297"

    private func log(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    // MARK: - Parsing

    func testParsesFocusNullAndLaunchLines() {
        let lines = ClaudeFocusLog.lines(in: log([
            "2026-11-27 12:25:48 [info] [CCD] LocalSessions.setFocusedSession: sessionId=null",
            "2026-11-27 12:25:48 [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(idA)",
            "2026-11-27 12:26:00 [info] [SkillsPlugin] Window focused — polling now",
            "2026-11-27 12:30:00 [info] [startup-perf] main window created 518 ms after launch, state { visible: false }",
            "2026-11-27 12:31:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=garbage",
        ]), timeZone: utc)
        XCTAssertEqual(lines, [
            .init(occurredAt: date("2026-11-27 12:25:48"), kind: .focus, localSessionID: nil),
            .init(occurredAt: date("2026-11-27 12:25:48"), kind: .focus, localSessionID: idA),
            .init(occurredAt: date("2026-11-27 12:30:00"), kind: .launch, localSessionID: nil),
        ])
    }

    func testLinesSharingASecondKeepFileOrderAcrossReads() {
        var counter: (second: Date?, seq: Int) = (nil, 0)
        let first = ClaudeFocusLog.events(from: ClaudeFocusLog.lines(in: log([
            "2026-11-27 12:25:48 [info] [CCD] LocalSessions.setFocusedSession: sessionId=null",
        ]), timeZone: utc), counter: &counter)
        let second = ClaudeFocusLog.events(from: ClaudeFocusLog.lines(in: log([
            "2026-11-27 12:25:48 [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(idA)",
            "2026-11-27 12:25:49 [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(idB)",
        ]), timeZone: utc), counter: &counter)
        XCTAssertEqual((first + second).map(\.seq), [0, 1, 0])
    }

    func testLogFilesComeOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["main.log", "main1.log", "main3.log", "main2.log", "main-window.log", "claude.ai-web.log"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(ClaudeFocusLog.logFiles(in: dir).map(\.lastPathComponent),
                       ["main3.log", "main2.log", "main1.log", "main.log"])
    }

    // MARK: - Timeline

    func testTimelineAnswersWhatWasInFront() {
        var counter: (second: Date?, seq: Int) = (nil, 0)
        let events = ClaudeFocusLog.events(from: ClaudeFocusLog.lines(in: log([
            "2026-11-27 09:00:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(idA)",
            "2026-11-27 09:10:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=null",
            "2026-11-27 09:10:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(idB)",
            "2026-11-27 09:20:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=null",
            "2026-11-27 09:30:00 [info] [startup-perf] main window created 500 ms after launch",
        ]), timeZone: utc), counter: &counter)
        let timeline = ClaudeFocusTimeline(events: events.reversed())
        XCTAssertEqual(timeline.focus(at: date("2026-11-27 08:59:59")), .unknown)
        XCTAssertEqual(timeline.focus(at: date("2026-11-27 09:05:00")), .session(localID: idA))
        // null then B in the same second is a switch to B.
        XCTAssertEqual(timeline.focus(at: date("2026-11-27 09:10:00")), .session(localID: idB))
        XCTAssertEqual(timeline.focus(at: date("2026-11-27 09:25:00")), .noSession)
        // After a restart nothing is known until the next focus line.
        XCTAssertEqual(timeline.focus(at: date("2026-11-27 09:31:00")), .unknown)
    }

    // MARK: - Storage and backfill

    func testStoringTheSameLinesTwiceKeepsOneCopy() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let e = ClaudeFocusEvent(occurredAt: date("2026-11-27 09:00:00"), seq: 0, kind: .focus,
                                 localSessionID: idA, cliSessionID: nil)
        try db.insertClaudeFocusEvents([e])
        var resolved = e
        resolved.cliSessionID = "cli-a"
        try db.insertClaudeFocusEvents([resolved, e])
        XCTAssertEqual(try db.allClaudeFocusEvents(), [resolved])
    }

    func testBackfillGivesSamplesTheSessionHistoryShowsAndNoOther() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDir = root.appendingPathComponent("acct/org", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"sessionId":"\#(idA)","cliSessionId":"cli-a","cwd":"/nowhere","title":"Fix it","createdAt":1795000000000}"#
        try Data(json.utf8).write(to: sessionDir.appendingPathComponent("\(idA).json"))

        try db.insertClaudeFocusEvents([
            ClaudeFocusEvent(occurredAt: date("2026-11-27 09:00:00"), seq: 0, kind: .focus, localSessionID: idA, cliSessionID: nil),
            ClaudeFocusEvent(occurredAt: date("2026-11-27 09:10:00"), seq: 0, kind: .focus, localSessionID: nil, cliSessionID: nil),
        ])
        func sample(_ t: String, _ app: String, title: String? = nil, idle: Bool = false) -> ActivitySample {
            ActivitySample(id: nil, capturedAt: date(t), appBundleID: app, appName: nil, windowTitle: title,
                           chromeURL: nil, chromeHost: nil, gitRepoPath: nil, gitRemoteURL: nil, isIdle: idle)
        }
        let before = try db.insert(sample("2026-11-27 08:59:00", ClaudeFocusLog.bundleID))
        let during = try db.insert(sample("2026-11-27 09:05:00", ClaudeFocusLog.bundleID))
        let idle = try db.insert(sample("2026-11-27 09:06:00", ClaudeFocusLog.bundleID, idle: true))
        let chat = try db.insert(sample("2026-11-27 09:15:00", ClaudeFocusLog.bundleID))

        AgentFocusRecorder.backfillSamples(database: db, desktopSessions: ClaudeDesktopSessions(root: root),
                                           codexThreads: CodexThreads(directory: root))
        let byID = try db.dbQueue.read { try ActivitySample.fetchAll($0) }
            .reduce(into: [Int64: String?]()) { $0[$1.id!] = $1.agentSessionID }
        XCTAssertEqual(byID[before.id!], .some(nil))
        XCTAssertEqual(byID[during.id!], .some("cli-a"))
        XCTAssertEqual(byID[idle.id!], .some(nil))
        XCTAssertEqual(byID[chat.id!], .some(nil))
        // The focused session gets a row so its repo and a pin can attribute it.
        let row = try XCTUnwrap(try db.session(id: "cli-a"))
        XCTAssertEqual(row.cwd, "/nowhere")
        XCTAssertNotNil(row.endedAt, "a placeholder row is closed until a hook reopens it")
    }

    // MARK: - Codex

    func testCodexTitleMatchesOneUserThreadOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = try DatabaseQueue(path: dir.appendingPathComponent("state_5.sqlite").path)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, cwd TEXT,
                                      git_origin_url TEXT, thread_source TEXT);
                INSERT INTO threads VALUES ('t1', 'Review PR 624', NULL, '/r', 'git@github.com:o/r.git', 'user');
                INSERT INTO threads VALUES ('t2', 'Same name', NULL, '/a', NULL, 'user');
                INSERT INTO threads VALUES ('t3', 'x', 'Same name', '/b', NULL, 'user');
                INSERT INTO threads VALUES ('t4', 'Subagent work', NULL, '/c', NULL, 'subagent');
                """)
        }
        try q.close()
        let threads = CodexThreads(directory: dir)
        XCTAssertEqual(threads.thread(title: "Review PR 624")?.storedSessionID, "codex:t1")
        XCTAssertEqual(threads.thread(title: "Review PR 624")?.gitOriginURL, "git@github.com:o/r.git")
        XCTAssertNil(threads.thread(title: "Same name"), "a title two threads share stays unresolved")
        XCTAssertNil(threads.thread(title: "Subagent work"))
        XCTAssertNil(threads.thread(title: "ChatGPT"))
    }
}
