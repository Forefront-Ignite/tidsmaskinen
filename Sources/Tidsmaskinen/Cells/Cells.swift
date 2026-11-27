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

    static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { throw CellsError.invalidToken }
        try KeychainStore.setData(data, account: keychainAccount)
    }

    static func clearToken() {
        _ = KeychainStore.delete(account: keychainAccount)
    }
}

enum CellsError: Error, CustomStringConvertible {
    case missingToken, invalidToken, unauthorized, forbidden
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    var description: String {
        switch self {
        case .missingToken:       return "No Cells token configured."
        case .invalidToken:       return "Token is empty or unreadable."
        case .unauthorized:       return "Cells rejected the token (401). Paste a new one in Settings."
        case .forbidden:          return "Cells refused the request (403). The token may predate call history access."
        case .http(let s, let b): return "Cells returned HTTP \(s): \(b.prefix(200))"
        case .transport(let m):   return "Network error talking to Cells: \(m)"
        case .decoding(let m):    return "Could not read the Cells response: \(m)"
        }
    }

    var isAuthFailure: Bool {
        switch self {
        case .missingToken, .invalidToken, .unauthorized: return true
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

    static let databaseTableName = "cells_calls"

    static func encodeStays(_ stays: [CellsAPI.Stay]) -> String {
        let rows: [[Double?]] = stays.map { [$0.joinedAt.timeIntervalSince1970, $0.leftAt?.timeIntervalSince1970] }
        return (try? String(data: JSONEncoder().encode(rows), encoding: .utf8)) ?? "[]"
    }

    /// The person's stays as intervals. A stay still open ends with the call,
    /// or now while the call is live; all are kept inside the call itself.
    func stays(now: Date = Date()) -> [DateInterval] {
        guard let data = staysJSON.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[Double?]].self, from: data) else { return [] }
        let callEnd = endedAt ?? (isLive ? now : startedAt)
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

/// The person's call stays, to find the call a Cells sample was taken in.
struct CellsCallIndex {
    private let stays: [(span: DateInterval, call: CellsCall)]

    /// Ignored calls are left out: their minutes are ordinary Cells time.
    init(calls: [CellsCall], now: Date = Date()) {
        stays = calls.filter { !$0.isIgnored }
            .flatMap { call in call.stays(now: now).map { ($0, call) } }
            .sorted { $0.span.start < $1.span.start }
    }

    var isEmpty: Bool { stays.isEmpty }

    /// The call a sample of the Cells app was captured in, if any.
    func call(for sample: ActivitySample) -> CellsCall? {
        guard !stays.isEmpty, ActivitySample.isCells(sample.appBundleID) else { return nil }
        var lo = 0, hi = stays.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stays[mid].span.start <= sample.capturedAt { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        while i >= 0 {
            let s = stays[i]
            if s.span.contains(sample.capturedAt) && sample.capturedAt < s.span.end { return s.call }
            if sample.capturedAt.timeIntervalSince(s.span.start) > 86_400 { break }
            i -= 1
        }
        return nil
    }

    /// A sample counts toward focus: active, or the Cells app in front during
    /// one of the person's calls (listening is no typing).
    func isActive(_ sample: ActivitySample) -> Bool {
        !sample.isIdle || call(for: sample) != nil
    }
}

/// Reads Cells and stores chats and calls. Keeps manual pins and ignores.
struct CellsSync {
    let database: AppDatabase
    let client: CellsClient

    /// How far back the first sync reads.
    static let firstSyncDays: Double = 56
    /// Recent calls are read again: a stay can close after the call was first seen.
    static let overlapSeconds: TimeInterval = 2 * 86_400

    func runSync(now: Date = Date()) async throws -> Date {
        let chats = try await client.chats()
        let names = Dictionary((try? await client.members())?.map { ($0.id, $0.name) } ?? [], uniquingKeysWith: { a, _ in a })
        try database.replaceCellsChats(chats.map { chat in
            CellsChat(id: chat.id,
                      name: chat.kind == "dm" ? (chat.peerId.flatMap { names[$0] } ?? chat.name) : chat.name,
                      kind: chat.kind, externalOf: chat.externalOf,
                      ccCustomerID: chat.commandCenter?.customerId, ccProjectID: chat.commandCenter?.projectId,
                      ccProjectName: chat.commandCenter?.projectName, syncedAt: now)
        })

        let stopAt = (try database.latestCellsCallStart()).map { $0.addingTimeInterval(-Self.overlapSeconds) }
            ?? now.addingTimeInterval(-Self.firstSyncDays * 86_400)
        var cursor: String?
        var calls: [CellsAPI.Call] = []
        for _ in 0..<60 {
            let page = try await client.recentCalls(cursor: cursor)
            calls += page.items
            cursor = page.nextCursor
            if cursor == nil || (page.items.last.map { $0.startedAt < stopAt } ?? true) { break }
        }
        try database.upsertCellsCalls(calls.map { c in
            CellsCall(id: c.id, chatID: c.channelId, startedAt: c.startedAt, endedAt: c.endedAt, isLive: c.live,
                      staysJSON: CellsCall.encodeStays(c.mine), customerID: nil, projectID: nil, syncedAt: now)
        })
        return now
    }
}
