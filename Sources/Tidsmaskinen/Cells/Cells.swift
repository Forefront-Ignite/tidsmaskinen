import Foundation
import GRDB

// Cells, where calls happen now. With a read-only personal access token
// (`cells_pat_…`) Tidsmaskinen reads the person's chats and their own call
// history: which Cell each chat is, the Cell's Command Center customer and
// project, and when the person joined and left each call. Nothing is written
// to Cells. See Cells' `cells-tidsmaskinen-api` notes (Cells PR #510).
//
// A call counts only for the minutes Cells is in front during the person's
// own stays in it; inside those stays the idle rule pauses (listening is no
// typing). A call in a project Cell takes that Cell's customer; a DM or group
// call is a Review item until pinned.

enum CellsAuth {
    static let keychainAccount = "cells-token"

    static func loadToken() -> String? {
        guard let data = KeychainStore.getData(account: keychainAccount),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Saves the token for the base URL in effect now: it is only ever sent
    /// to that origin, so editing the URL can't hand it to another server.
    static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let origin = origin(of: AppSettings.cellsBaseURL) else { throw CellsError.invalidToken }
        try KeychainStore.setData(data, account: keychainAccount)
        AppSettings.setCellsTokenOrigin(origin)
    }

    /// True once the token is gone (or was never there).
    @discardableResult
    static func clearToken() -> Bool {
        let status = KeychainStore.delete(account: keychainAccount)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        AppSettings.setCellsTokenOrigin(nil)
        return true
    }

    static func origin(of url: String) -> String? {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return nil }
        return c.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

enum CellsError: Error, CustomStringConvertible {
    case missingToken, invalidToken, unauthorized, forbidden, originChanged, incompleteHistory
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    var description: String {
        switch self {
        case .missingToken:       return "No Cells token configured."
        case .invalidToken:       return "Token is empty or unreadable."
        case .unauthorized:       return "Cells rejected the token (401). Paste a new one in Settings."
        case .forbidden:          return "Cells refused the request (403). The token may predate call history access."
        case .originChanged:      return "The Cells base URL changed since the token was saved. Paste a token for the new URL."
        case .incompleteHistory:  return "Cells call history was only partly read; the rest is read on the next sync."
        case .http(let s, let b): return "Cells returned HTTP \(s): \(b.prefix(200))"
        case .transport(let m):   return "Network error talking to Cells: \(m)"
        case .decoding(let m):    return "Could not read the Cells response: \(m)"
        }
    }

    var isAuthFailure: Bool {
        switch self {
        // A missing token can be a locked Keychain for a moment: not a reason to stop syncing.
        case .invalidToken, .unauthorized: return true
        default: return false
        }
    }
}

/// The Cells API as a read-only token sees it.
enum CellsAPI {
    struct Chat: Decodable, Sendable {
        let id: String
        let name: String
        let kind: String
        let externalOf: String?
        let peerId: String?
        let commandCenter: CommandCenterLink?

        struct CommandCenterLink: Decodable, Sendable {
            let customerId: String?
            let projectId: String?
            let projectName: String?
        }
    }

    struct Member: Decodable, Sendable {
        let id: String
        let name: String
    }

    struct Stay: Decodable, Sendable, Equatable {
        let joinedAt: Date
        let leftAt: Date?
    }

    struct Call: Decodable, Sendable {
        let id: String
        let channelId: String
        let startedAt: Date
        let endedAt: Date?
        let live: Bool
        /// The token owner's own stays, one per join, oldest first.
        let mine: [Stay]
    }

    struct CallPage: Decodable, Sendable {
        let items: [Call]
        let nextCursor: String?
    }

    /// ISO 8601 with or without fractional seconds (Cells sends milliseconds).
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }
}

actor CellsClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func chats() async throws -> [CellsAPI.Chat] { try await get("/api/channels") }

    /// Workspace members, for DM names. Tolerates a wrapped array.
    func members() async throws -> [CellsAPI.Member] {
        let data = try await getData("/api/members")
        let decoder = CellsAPI.decoder()
        if let list = try? decoder.decode([CellsAPI.Member].self, from: data) { return list }
        struct Wrapped: Decodable { let members: [CellsAPI.Member]? ; let people: [CellsAPI.Member]? }
        let w = try decoder.decode(Wrapped.self, from: data)
        return w.members ?? w.people ?? []
    }

    func recentCalls(cursor: String?, limit: Int = 50) async throws -> CellsAPI.CallPage {
        var query = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        return try await get("/api/huddles/recent", query: query)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await getData(path, query: query)
        do { return try CellsAPI.decoder().decode(T.self, from: data) }
        catch { throw CellsError.decoding(String(describing: error)) }
    }

    private func getData(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard let token = CellsAuth.loadToken() else { throw CellsError.missingToken }
        let base = AppSettings.cellsBaseURL
        guard let origin = CellsAuth.origin(of: base), origin == AppSettings.cellsTokenOrigin else { throw CellsError.originChanged }
        guard var components = URLComponents(string: base) else { throw CellsError.transport("Invalid base URL: \(base)") }
        components.path = (components.path + path).replacingOccurrences(of: "//", with: "/")
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw CellsError.transport("Could not build a URL from \(base)") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw CellsError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw CellsError.transport("Non-HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw CellsError.unauthorized
        case 403: throw CellsError.forbidden
        default: throw CellsError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Stored

/// A chat the person can see in Cells, with its Cell's Command Center link.
struct CellsChat: Codable, FetchableRecord, PersistableRecord, Equatable, Hashable, Sendable {
    var id: String
    /// Display name: a DM shows the other person.
    var name: String
    /// `cell`, `dm` or `group`.
    var kind: String
    /// For a Cell's External chat: the Cell it belongs to (its link is the Cell's).
    var externalOf: String?
    var ccCustomerID: String?
    var ccProjectID: String?
    var ccProjectName: String?
    var syncedAt: Date

    static let databaseTableName = "cells_chats"
}

/// One call the person was in, with their own stays and a manual pin.
struct CellsCall: Codable, FetchableRecord, PersistableRecord, Equatable, Hashable, Sendable {
    var id: String
    var chatID: String
    var startedAt: Date
    var endedAt: Date?
    var isLive: Bool
    /// `[[joinedAt, leftAt|null]]` in seconds since 1970.
    var staysJSON: String
    /// Set from Review for a DM or group call (or to override the Cell).
    var customerID: String?
    var projectID: String?
    var isIgnored: Bool = false
    var syncedAt: Date
    /// The chat's Cell link when the call was first synced, so leaving or
    /// relinking the Cell later doesn't move this call's time.
    var ccCustomerID: String? = nil
    var ccProjectID: String? = nil

    static let databaseTableName = "cells_calls"

    /// How long past the last sync a still-open stay is believed.
    static let liveGrace: TimeInterval = 15 * 60

    static func encodeStays(_ stays: [CellsAPI.Stay]) -> String {
        let rows: [[Double?]] = stays.map { [$0.joinedAt.timeIntervalSince1970, $0.leftAt?.timeIntervalSince1970] }
        return (try? String(data: JSONEncoder().encode(rows), encoding: .utf8)) ?? "[]"
    }

    /// The person's stays as intervals. A stay still open ends with the call,
    /// or now while the call is live; all are kept inside the call itself.
    func stays(now: Date = Date()) -> [DateInterval] {
        guard let data = staysJSON.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[Double?]].self, from: data) else { return [] }
        // A call last seen live is believed only a little past that sighting:
        // one that rang out unanswered disappears from history and must not
        // keep claiming Cells time.
        let callEnd = endedAt ?? (isLive ? min(now, syncedAt.addingTimeInterval(Self.liveGrace)) : startedAt)
        return rows.compactMap { row in
            guard let j = row.first ?? nil else { return nil }
            let joined = max(Date(timeIntervalSince1970: j), startedAt)
            let left = min((row.count > 1 ? row[1] : nil).map { Date(timeIntervalSince1970: $0) } ?? callEnd, callEnd)
            return left > joined ? DateInterval(start: joined, end: left) : nil
        }
    }
}

extension ActivitySample {
    /// Bundle ids of the Cells app and its dev builds.
    static func isCells(_ bundleID: String?) -> Bool { bundleID?.hasPrefix("studio.ignite.cells") == true }
}

/// The person's call stays, to find which call a moment of Cells time was in.
struct CellsCallIndex {
    private let stays: [(span: DateInterval, call: CellsCall)]
    /// The latest end among `stays[0...i]`, so a search can stop early.
    private let maxEnd: [Date]

    /// Ignored calls are left out unless asked for: their minutes are
    /// ordinary Cells time.
    init(calls: [CellsCall], now: Date = Date(), includeIgnored: Bool = false) {
        let sorted = calls.filter { includeIgnored || !$0.isIgnored }
            .flatMap { call in call.stays(now: now).map { ($0, call) } }
            .sorted { $0.0.start < $1.0.start }
        stays = sorted
        var running = Date.distantPast
        maxEnd = sorted.map { running = max(running, $0.0.end); return running }
    }

    var isEmpty: Bool { stays.isEmpty }

    /// `piece` cut at join and leave times: the parts inside a stay with its
    /// call, the rest with nil. Overlapping stays: the earlier one wins.
    func split(_ piece: DateInterval) -> [(DateInterval, CellsCall?)] {
        var hits: [(DateInterval, CellsCall)] = []
        // Stays starting before the piece ends; walk back while one could still reach it.
        var a = 0, b = stays.count
        while a < b { let m = (a + b) / 2; if stays[m].span.start < piece.end { a = m + 1 } else { b = m } }
        var i = a - 1
        while i >= 0, maxEnd[i] > piece.start {
            if let x = stays[i].span.intersectionIfPositive(with: piece) { hits.append((x, stays[i].call)) }
            i -= 1
        }
        guard !hits.isEmpty else { return [(piece, nil)] }
        hits.sort { $0.0.start < $1.0.start }
        var out: [(DateInterval, CellsCall?)] = []
        var cursor = piece.start
        for (span, call) in hits where span.end > cursor {
            let start = max(span.start, cursor)
            if start > cursor { out.append((DateInterval(start: cursor, end: start), nil)) }
            out.append((DateInterval(start: start, end: span.end), call))
            cursor = span.end
        }
        if cursor < piece.end { out.append((DateInterval(start: cursor, end: piece.end), nil)) }
        return out
    }

    /// The call a single moment falls in.
    func call(at date: Date) -> CellsCall? {
        guard !stays.isEmpty else { return nil }
        return split(DateInterval(start: date, duration: 1)).first { $0.1 != nil }?.1
    }

    /// Whether a sample may hold call time: the Cells app in front, idle or
    /// not (listening is no typing). Which part is call time is `billable`.
    func mayCount(_ sample: ActivitySample) -> Bool {
        !sample.isIdle || (!stays.isEmpty && ActivitySample.isCells(sample.appBundleID))
    }

    /// The parts of a sample's focus pieces that bill, each with its call
    /// (nil: ordinary attribution). Inside your stay, Cells time is the
    /// call's; outside it an idle Cells sample bills nothing. A sample you
    /// assigned by hand stays yours.
    func billable(_ sample: ActivitySample, pieces: [DateInterval]) -> [(DateInterval, CellsCall?)] {
        guard !stays.isEmpty, ActivitySample.isCells(sample.appBundleID), sample.customerID == nil else {
            return sample.isIdle ? [] : pieces.map { ($0, nil) }
        }
        return pieces.flatMap(split).filter { $0.1 != nil || !sample.isIdle }
    }
}

/// Reads Cells and stores chats and calls. Keeps manual pins and ignores.
struct CellsSync {
    let database: AppDatabase
    let client: CellsClient

    /// How far back the first full scan reads.
    static let firstSyncDays: Double = 56
    /// Recent calls are read again: a stay can close after the call was first seen.
    static let overlapSeconds: TimeInterval = 2 * 86_400
    static let maxPages = 300

    func runSync(now: Date = Date()) async throws -> Date {
        let chats = try await client.chats()
        let names = Dictionary((try? await client.members())?.map { ($0.id, $0.name) } ?? [], uniquingKeysWith: { a, _ in a })
        let stored = chats.map { chat in
            CellsChat(id: chat.id,
                      name: chat.kind == "dm" ? (chat.peerId.flatMap { names[$0] } ?? chat.name) : chat.name,
                      kind: chat.kind, externalOf: chat.externalOf,
                      ccCustomerID: chat.commandCenter?.customerId, ccProjectID: chat.commandCenter?.projectId,
                      ccProjectName: chat.commandCenter?.projectName, syncedAt: now)
        }
        // Chats you no longer see keep their last known link, so earlier
        // time in them keeps its customer.
        try database.upsertCellsChats(stored)
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func link(_ chatID: String) -> (String?, String?) {
            guard var chat = byID[chatID] else { return (nil, nil) }
            if let parent = chat.externalOf.flatMap({ byID[$0] }) { chat = parent }
            return (chat.ccCustomerID, chat.ccProjectID)
        }

        // Until one scan has read back to the first-sync horizon, read that far;
        // after that, from a little before the newest stored call.
        let horizon = now.addingTimeInterval(-Self.firstSyncDays * 86_400)
        let completeSince = AppSettings.cellsHistoryCompleteSince
        let stopAt = completeSince == nil ? horizon
            : ((try database.latestCellsCallStart()).map { $0.addingTimeInterval(-Self.overlapSeconds) } ?? horizon)
        var cursor: String?
        var calls: [CellsAPI.Call] = []
        var reached = false
        for _ in 0..<Self.maxPages {
            let page = try await client.recentCalls(cursor: cursor)
            calls += page.items
            cursor = page.nextCursor
            // A page can come back empty with more to read (Cells filters after paging).
            if cursor == nil || (page.items.last.map { $0.startedAt < stopAt } ?? false) { reached = true; break }
        }
        try database.upsertCellsCalls(calls.map { c in
            let (customer, project) = link(c.channelId)
            return CellsCall(id: c.id, chatID: c.channelId, startedAt: c.startedAt, endedAt: c.endedAt, isLive: c.live,
                             staysJSON: CellsCall.encodeStays(c.mine), customerID: nil, projectID: nil, syncedAt: now,
                             ccCustomerID: customer, ccProjectID: project)
        })
        guard reached else { throw CellsError.incompleteHistory }
        // A call stored as live that a complete scan no longer lists ended
        // (a call that rang out unanswered becomes a missed-call event).
        try database.closeCellsCalls(startedSince: stopAt, notIn: Set(calls.map(\.id)))
        if completeSince == nil { AppSettings.setCellsHistoryCompleteSince(horizon) }
        return now
    }
}
