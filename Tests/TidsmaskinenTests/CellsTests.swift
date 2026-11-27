import XCTest
@testable import Tidsmaskinen

/// Cells: chats take their Cell's Command Center customer, and a call counts
/// for the minutes Cells is in front during your own stays, idle included.
@MainActor
final class CellsTests: XCTestCase {
    private let cal = Calendar.weekStartingMonday()
    private func at(_ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h, minute: mi))!
    }
    private var week: DateInterval { cal.currentWeekInterval(reference: at(12)) }

    private let acme = Customer(id: "acme", name: "Acme", color: nil, createdAt: Date(),
                                externalSource: ExternalSource.commandCenter.rawValue, externalID: "cc-acme")
    private var launch: Project {
        Project(id: "launch", customerID: "acme", name: "Launch", color: nil, createdAt: Date(),
                externalSource: ExternalSource.commandCenter.rawValue, externalID: "cc-launch")
    }
    private func chat(_ id: String, kind: String = "cell", customer: String? = nil, project: String? = nil,
                      externalOf: String? = nil) -> CellsChat {
        CellsChat(id: id, name: id, kind: kind, externalOf: externalOf, ccCustomerID: customer,
                  ccProjectID: project, ccProjectName: nil, syncedAt: Date())
    }
    private var matcher: RuleMatcher {
        RuleMatcher.make(customers: [acme], projects: [launch], rules: [],
                         cellsChats: [chat("cell", customer: "cc-acme", project: "cc-launch"),
                                      chat("ext", externalOf: "cell"), chat("dm", kind: "dm")])
    }
    private func call(_ id: String, chat: String, from: Date, to: Date, stays: [(Date, Date?)],
                      pinned: String? = nil, ignored: Bool = false) -> CellsCall {
        CellsCall(id: id, chatID: chat, startedAt: from, endedAt: to, isLive: false,
                  staysJSON: CellsCall.encodeStays(stays.map { CellsAPI.Stay(joinedAt: $0.0, leftAt: $0.1) }),
                  customerID: pinned, projectID: nil, isIgnored: ignored, syncedAt: Date())
    }
    private func samples(_ from: Date, minutes: Int, app: String = "studio.ignite.cells", idle: Bool = false,
                         chat: String? = nil) -> [ActivitySample] {
        (0..<(minutes * 4)).map { i in
            ActivitySample(id: nil, capturedAt: from.addingTimeInterval(Double(i) * 15), appBundleID: app, appName: nil,
                           windowTitle: nil, chromeURL: nil, chromeHost: nil, gitRepoPath: nil, gitRemoteURL: nil,
                           isIdle: idle, customerID: nil, projectID: nil, cellsChatID: chat)
        }
    }
    private func hours(_ r: WeeklyReport, _ id: String) -> Double {
        r.rows.first { $0.id == id }?.rawPerDayHours.reduce(0, +) ?? 0
    }

    // MARK: - API and storage

    func testDecodesCallHistoryAndChats() throws {
        let page = try CellsAPI.decoder().decode(CellsAPI.CallPage.self, from: Data("""
            {"items":[{"id":"h1","channelId":"c1","messageId":"m","topicId":"t","startedAt":"2026-11-27T13:54:00.000Z",
              "endedAt":null,"live":true,"startedBy":{"userId":"u","name":"U"},"participants":[],"participant":true,
              "replies":0,"mine":[{"joinedAt":"2026-11-27T13:56:00.000Z","leftAt":"2026-11-27T14:03:00.000Z"},
                                  {"joinedAt":"2026-11-27T14:06:00Z","leftAt":null}]}],"nextCursor":null}
            """.utf8))
        XCTAssertEqual(page.items.first?.mine.count, 2)
        XCTAssertNil(page.items.first?.mine.last?.leftAt)
        let chats = try CellsAPI.decoder().decode([CellsAPI.Chat].self, from: Data("""
            [{"id":"c1","name":"Launch","kind":"cell","project":true,"externalOf":null,"peerId":null,"joined":true,
              "customer":{"id":"https://x","name":"Acme"},"commandCenter":{"customerId":"cc-acme","projectId":"cc-launch","projectName":"Launch"}},
             {"id":"d1","name":"x","kind":"dm","externalOf":null,"peerId":"u2","commandCenter":null}]
            """.utf8))
        XCTAssertEqual(chats.first?.commandCenter?.projectId, "cc-launch")
        XCTAssertNil(chats.last?.commandCenter)
    }

    func testOpenStayEndsWithTheCallAndStaysClampToIt() {
        let c = call("h", chat: "dm", from: at(10), to: at(10, 30),
                     stays: [(at(9, 50), at(10, 10)), (at(10, 20), nil)])
        XCTAssertEqual(c.stays(), [DateInterval(start: at(10), end: at(10, 10)),
                                   DateInterval(start: at(10, 20), end: at(10, 30))])
    }

    func testResyncKeepsPinAndIgnore() throws {
        let db = try AppDatabase.inMemoryForTesting()
        let first = call("h", chat: "dm", from: at(10), to: at(10, 30), stays: [(at(10), nil)])
        try db.upsertCellsCalls([first])
        try db.setCellsCallAttribution(id: "h", customerID: "acme", projectID: nil)
        try db.setCellsCallIgnored(id: "h", isIgnored: true)
        var later = first
        later.endedAt = at(10, 40)
        try db.upsertCellsCalls([later])
        let stored = try XCTUnwrap(db.cellsCalls(in: week).first)
        XCTAssertEqual(stored.endedAt, at(10, 40))
        XCTAssertEqual(stored.customerID, "acme")
        XCTAssertTrue(stored.isIgnored)
    }

    func testChatIdComesFromTheWindowDocument() {
        XCTAssertEqual(Probes.cellsChatID(fromDocument: "https://cells.ignitestudio.eu/?cell=abc123"), "abc123")
        XCTAssertNil(Probes.cellsChatID(fromDocument: "https://cells.ignitestudio.eu/"))
        XCTAssertNil(Probes.cellsChatID(fromDocument: "file:///Users/x/doc.txt"))
    }

    // MARK: - Attribution

    func testChatsTakeTheirCellsCommandCenterLink() {
        let m = matcher
        XCTAssertEqual(m.attribute(cellsChatID: "cell")?.project?.id, "launch")
        XCTAssertEqual(m.attribute(cellsChatID: "ext")?.customer?.id, "acme", "an External chat follows its Cell")
        XCTAssertNil(m.attribute(cellsChatID: "dm"))
        XCTAssertNil(m.attribute(cellsChatID: "unknown"))
        let s = samples(at(9), minutes: 1, chat: "cell")[0]
        XCTAssertEqual(m.attribute(s).project?.id, "launch")
    }

    func testCallMinutesCountWhileCellsIsInFrontIdleIncluded() {
        let c = call("h", chat: "cell", from: at(10), to: at(11), stays: [(at(10), at(10, 30))])
        // In the call 10:00–10:30: Cells in front but idle (listening); 10:30–10:45 idle after leaving.
        let work = samples(at(10), minutes: 45, idle: true)
        let r = WeeklyReport.compute(week: week, samples: work, cellsCalls: [c], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(r, "acme/launch"), 0.5, accuracy: 0.001)
        XCTAssertEqual(r.breakdownsByRowID["acme/launch"]?.topContributors.first?.kindLabel, "Cells call")
    }

    func testOnlyCellsInFrontCounts() {
        let c = call("h", chat: "cell", from: at(10), to: at(11), stays: [(at(10), at(11))])
        let elsewhere = samples(at(10), minutes: 30, app: "com.microsoft.VSCode", idle: true)
        let r = WeeklyReport.compute(week: week, samples: elsewhere, cellsCalls: [c], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(r.grandTotal + r.unattributedTotal, 0, accuracy: 0.001)
    }

    func testDmCallIsOpenUntilPinnedAndIgnoredCallCountsNothing() {
        let dm = call("h", chat: "dm", from: at(10), to: at(10, 30), stays: [(at(10), at(10, 30))])
        let work = samples(at(10), minutes: 30, idle: true)
        let open = WeeklyReport.compute(week: week, samples: work, cellsCalls: [dm], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(open.unattributedPerDay.reduce(0, +), 0.5, accuracy: 0.001)
        var pinned = dm
        pinned.customerID = "acme"
        let done = WeeklyReport.compute(week: week, samples: work, cellsCalls: [pinned], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(hours(done, "acme"), 0.5, accuracy: 0.001)
        var ignored = dm
        ignored.isIgnored = true
        let none = WeeklyReport.compute(week: week, samples: work, cellsCalls: [ignored], matcher: matcher, sampleIntervalSeconds: 15)
        XCTAssertEqual(none.grandTotal + none.unattributedTotal, 0, accuracy: 0.001)
    }

    func testReviewListsDmCallsOpenAndCellCallsAttributed() throws {
        let db = try AppDatabase.inMemoryForTesting()
        try db.upsert(acme)
        try db.upsert(launch)
        try db.replaceCellsChats([chat("cell", customer: "cc-acme", project: "cc-launch"), chat("dm", kind: "dm")])
        try db.upsertCellsCalls([call("dmcall", chat: "dm", from: at(9), to: at(9, 20), stays: [(at(9), at(9, 20))]),
                                 call("cellcall", chat: "cell", from: at(10), to: at(10, 20), stays: [(at(10), at(10, 20))])])
        for s in samples(at(9), minutes: 20, idle: true) + samples(at(10), minutes: 20, idle: true) { _ = try db.insert(s) }
        let rows = try ReviewQueue.rows(database: db, interval: week, sampleIntervalSeconds: 15,
                                        idleThresholdSeconds: 300, minMinutes: 5)
        XCTAssertEqual(rows.first { $0.id == "cells-call:dmcall" }?.status, .open)
        XCTAssertEqual(rows.first { $0.id == "cells-call:cellcall" }?.status,
                       .attributed(customerID: "acme", projectID: "launch", scope: "Cell"))
        XCTAssertEqual(rows.first { $0.id == "cells-call:dmcall" }?.totalSeconds ?? 0, 1200, accuracy: 1)
    }
}
