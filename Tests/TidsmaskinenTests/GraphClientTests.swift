import XCTest
@testable import Tidsmaskinen

private final class GraphFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = query.first { $0.name == "page" }?.value
        let scenario = request.value(forHTTPHeaderField: "Authorization") ?? ""
        var status = 200
        let body: String
        if url.path == "/v1.0/me" {
            body = #"{"id":"user","userPrincipalName":"test@example.com"}"#
        } else if page == "2" {
            if scenario == "Bearer failure" {
                status = 503
                body = #"{"error":"unavailable"}"#
            } else {
                body = #"{"value":[{"id":"second","subject":"Second page","start":{"dateTime":"2026-09-14T11:00:00.0000000"},"end":{"dateTime":"2026-09-14T12:00:00.0000000"},"responseStatus":{"response":"accepted"}}]}"#
            }
        } else if scenario == "Bearer malformed" {
            body = #"{"value":[{"id":"second","start":{"dateTime":"invalid"},"end":{"dateTime":"invalid"}}]}"#
        } else if scenario == "Bearer tentative" {
            body = #"{"value":[{"id":"tentative","start":{"dateTime":"2026-09-14T09:00:00Z"},"end":{"dateTime":"2026-09-14T10:00:00Z"},"responseStatus":{"response":"tentativelyAccepted"}}]}"#
        } else if scenario == "Bearer cancelled-invalid" {
            body = #"{"value":[{"id":"cancelled","isCancelled":true,"start":{"dateTime":"invalid"},"end":{"dateTime":"invalid"}}]}"#
        } else if scenario == "Bearer cancelled" {
            body = #"{"value":[{"id":"cancelled","isCancelled":true,"start":{"dateTime":"2026-09-14T09:00:00Z"},"end":{"dateTime":"2026-09-14T10:00:00Z"},"responseStatus":{"response":"accepted"}}]}"#
        } else {
            let link = scenario == "Bearer untrusted"
                ? "https://example.com/calendar?page=2"
                : "https://graph.microsoft.com/v1.0/me/calendarView?page=2"
            body = """
            {"value":[{"id":"first","start":{"dateTime":"2026-09-14T09:00:00Z"},"end":{"dateTime":"2026-09-14T10:00:00Z"},"responseStatus":{"response":"accepted"}}],"@odata.nextLink":"\(link)"}
            """
        }
        // Pagination requests must preserve the timezone preference.
        if url.path.contains("calendarView"), request.value(forHTTPHeaderField: "Prefer") != "outlook.timezone=\"UTC\"" {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class GraphClientTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-09-14T00:00:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!

    private func client(_ scenario: String) -> GraphClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GraphFixtureProtocol.self]
        return GraphClient(session: URLSession(configuration: config), tokens: GraphTokens(
            accessToken: scenario, refreshToken: "unused", expiresAt: .distantFuture,
            userPrincipal: "test@example.com"
        ))
    }

    func testFetchIncludesAllPages() async throws {
        let events = try await client("success").fetchCalendarView(start: start, end: end)
        XCTAssertEqual(events.map(\.id), ["first", "second"])
    }

    func testCancelledMeetingsAreExcluded() async throws {
        let events = try await client("cancelled").fetchCalendarView(start: start, end: end)
        XCTAssertTrue(events.isEmpty)
    }

    /// A cancelled event is dropped before validation, so one with unparseable
    /// dates cannot make every future sync fail.
    func testCancelledMeetingWithInvalidDatesDoesNotPoisonSync() async throws {
        let events = try await client("cancelled-invalid").fetchCalendarView(start: start, end: end)
        XCTAssertTrue(events.isEmpty)
    }

    func testInvalidSnapshotDoesNotDeleteLocalCalendarHistory() async throws {
        for scenario in ["failure", "malformed", "untrusted"] {
            let db = try AppDatabase.inMemoryForTesting()
            let events = try await client("success").fetchCalendarView(start: start, end: end)
            var event = try XCTUnwrap(events.last)
            event.isIgnored = true
            try db.upsertEvents([event])
            let sync = CalendarSync(database: db, client: client(scenario))
            await sync.syncNow(since: start, until: end)
            XCTAssertNotNil(sync.lastError, scenario)
            let preserved = try XCTUnwrap(db.calendarEvents(ids: [event.id]).first)
            XCTAssertTrue(preserved.isIgnored, scenario)
        }
    }

    func testSuccessfulPagedSyncPreservesOverrides() async throws {
        let db = try AppDatabase.inMemoryForTesting()
        let events = try await client("success").fetchCalendarView(start: start, end: end)
        var event = try XCTUnwrap(events.last)
        event.isIgnored = true
        try db.upsertEvents([event])
        let sync = CalendarSync(database: db, client: client("success"))
        await sync.syncNow(since: start, until: end)
        XCTAssertNil(sync.lastError)
        XCTAssertEqual(sync.lastFetchedCount, 2)
        XCTAssertTrue(try XCTUnwrap(db.calendarEvents(ids: [event.id]).first).isIgnored)
    }


    func testChangingRSVPFilterPreservesSavedMeetingOverrides() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: SettingsKey.meetingRSVPFilter)
        defer { defaults.set(prior, forKey: SettingsKey.meetingRSVPFilter) }
        defaults.set(MeetingRSVPFilter.acceptedAndTentative.rawValue, forKey: SettingsKey.meetingRSVPFilter)
        let db = try AppDatabase.inMemoryForTesting()
        let sync = CalendarSync(database: db, client: client("tentative"))
        await sync.syncNow(since: start, until: end)
        var event = try XCTUnwrap(db.calendarEvents(in: DateInterval(start: start, end: end)).first)
        event.isIgnored = true
        try db.upsertEvents([event])

        defaults.set(MeetingRSVPFilter.acceptedOnly.rawValue, forKey: SettingsKey.meetingRSVPFilter)
        await sync.syncNow(since: start, until: end)
        XCTAssertNil(sync.lastError)
        XCTAssertTrue(try db.calendarEvents(in: DateInterval(start: start, end: end)).isEmpty)
        XCTAssertTrue(try db.recentCalendarEvents().isEmpty)
        XCTAssertTrue(try XCTUnwrap(db.calendarEvents(ids: [event.id]).first).isIgnored)

        defaults.set(MeetingRSVPFilter.acceptedAndTentative.rawValue, forKey: SettingsKey.meetingRSVPFilter)
        let restored = try XCTUnwrap(db.calendarEvents(in: DateInterval(start: start, end: end)).first)
        XCTAssertEqual(restored.id, event.id)
        XCTAssertTrue(restored.isIgnored)
    }

    func testOAuthFormEscapesReservedCharacters() {
        XCTAssertEqual(GraphClient.formEncoded(["token": "a+b&c=d?# /"]), "token=a%2Bb%26c%3Dd%3F%23%20%2F")
    }
}
