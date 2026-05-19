import Foundation

// MARK: - Persisted tokens

struct GraphTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userPrincipal: String?

    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)  // 60 s safety margin
    }
}

// MARK: - Errors

enum GraphError: Error, CustomStringConvertible {
    case notSignedIn
    case deviceCodeFailed(String)
    case deviceCodeRejected(String)
    case authorizationPending
    case tokenError(String)
    case tokenRefreshFailed(String)
    case calendarFetchFailed(String)
    case meFetchFailed(String)

    var description: String {
        switch self {
        case .notSignedIn: return "Not signed in to Microsoft."
        case .deviceCodeFailed(let m): return "Device code request failed: \(m)"
        case .deviceCodeRejected(let m): return "Sign-in was rejected/expired: \(m)"
        case .authorizationPending: return "Authorization still pending."
        case .tokenError(let m): return "Token error: \(m)"
        case .tokenRefreshFailed(let m): return "Token refresh failed: \(m)"
        case .calendarFetchFailed(let m): return "Calendar fetch failed: \(m)"
        case .meFetchFailed(let m): return "/me fetch failed: \(m)"
        }
    }
}

// MARK: - Public payloads

struct DeviceCodeResponse: Codable, Equatable {
    let userCode: String
    let deviceCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    let message: String?
}

struct GraphMe: Codable, Equatable {
    let id: String
    let userPrincipalName: String
    let displayName: String?
    let mail: String?
}

// MARK: - Client

actor GraphClient {
    static let scope = "Calendars.Read offline_access User.Read"
    private static let tokensAccount = "microsoft-graph-tokens"
    private static let graphBase = "https://graph.microsoft.com/v1.0"

    private var tokens: GraphTokens?

    /// Read live so changes in Settings take effect without restarting the actor.
    private var clientID: String { AppSettings.graphClientID }
    private var authorityBase: String {
        "https://login.microsoftonline.com/\(AppSettings.graphTenantID)/oauth2/v2.0"
    }

    init() {
        self.tokens = KeychainStore.getCodable(GraphTokens.self, account: Self.tokensAccount)
    }

    // MARK: - Public API

    var isSignedIn: Bool { tokens != nil }
    var signedInPrincipal: String? { tokens?.userPrincipal }

    func signOut() {
        KeychainStore.delete(account: Self.tokensAccount)
        tokens = nil
    }

    /// Step 1 of device-code flow: get a code to display.
    func requestDeviceCode() async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "\(authorityBase)/devicecode")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = formEncoded([
            "client_id": clientID,
            "scope": Self.scope
        ])
        req.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GraphError.deviceCodeFailed(Self.errorBody(data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DeviceCodeResponse.self, from: data)
    }

    /// Step 2: poll until tokens are issued or rejected.
    func pollForTokens(deviceCode: String, interval: Int) async throws -> GraphTokens {
        let baseInterval = max(2, interval)
        var currentInterval = baseInterval
        while true {
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)
            do {
                let tokens = try await exchangeDeviceCode(deviceCode)
                return tokens
            } catch GraphError.authorizationPending {
                currentInterval = baseInterval
                continue
            } catch let GraphError.tokenError(message) where message.contains("slow_down") {
                currentInterval = baseInterval + 5
                continue
            }
        }
    }

    private func exchangeDeviceCode(_ deviceCode: String) async throws -> GraphTokens {
        var req = URLRequest(url: URL(string: "\(authorityBase)/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = formEncoded([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": clientID,
            "device_code": deviceCode
        ])
        req.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 200 {
            return try await persistTokenResponse(data: data, fallbackRefresh: nil)
        }
        let err = decodeOAuthError(data)
        switch err.code {
        case "authorization_pending": throw GraphError.authorizationPending
        case "slow_down": throw GraphError.tokenError("slow_down")
        case "expired_token", "authorization_declined", "bad_verification_code":
            throw GraphError.deviceCodeRejected(err.description ?? err.code)
        default:
            throw GraphError.tokenError(err.description ?? err.code)
        }
    }

    /// Refresh the access token; persists new tokens and returns them.
    @discardableResult
    func refreshTokens() async throws -> GraphTokens {
        guard let current = tokens else { throw GraphError.notSignedIn }
        var req = URLRequest(url: URL(string: "\(authorityBase)/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = formEncoded([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": current.refreshToken,
            "scope": Self.scope
        ])
        req.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GraphError.tokenRefreshFailed(Self.errorBody(data))
        }
        return try await persistTokenResponse(data: data, fallbackRefresh: current.refreshToken)
    }

    func ensureValidAccessToken() async throws -> String {
        guard var t = tokens else { throw GraphError.notSignedIn }
        if t.isExpired {
            t = try await refreshTokens()
        }
        return t.accessToken
    }

    /// /me — also stamps userPrincipal into the cached tokens.
    @discardableResult
    func me() async throws -> GraphMe {
        let token = try await ensureValidAccessToken()
        var req = URLRequest(url: URL(string: "\(Self.graphBase)/me")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GraphError.meFetchFailed(Self.errorBody(data))
        }
        let me = try JSONDecoder().decode(GraphMe.self, from: data)

        // Refresh stored principal if it's missing or stale.
        if let current = tokens, current.userPrincipal != me.userPrincipalName {
            let updated = GraphTokens(
                accessToken: current.accessToken,
                refreshToken: current.refreshToken,
                expiresAt: current.expiresAt,
                userPrincipal: me.userPrincipalName
            )
            try? KeychainStore.setCodable(updated, account: Self.tokensAccount)
            tokens = updated
        }
        return me
    }

    /// Fetch calendar events between start and end (UTC). Filters by RSVP per AppSettings.
    func fetchCalendarView(start: Date, end: Date) async throws -> [CalendarEvent] {
        let token = try await ensureValidAccessToken()
        let me = try? await me()
        let userDomain = me?.userPrincipalName.split(separator: "@").last.map(String.init).map { $0.lowercased() }

        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "\(Self.graphBase)/me/calendarView")!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: isoOut.string(from: start)),
            URLQueryItem(name: "endDateTime", value: isoOut.string(from: end)),
            URLQueryItem(name: "$top", value: "200"),
            URLQueryItem(name: "$orderby", value: "start/dateTime"),
            URLQueryItem(name: "$select", value: "id,iCalUId,subject,bodyPreview,start,end,isAllDay,organizer,attendees,responseStatus,location,isOnlineMeeting,onlineMeetingProvider,createdDateTime,lastModifiedDateTime")
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GraphError.calendarFetchFailed(Self.errorBody(data))
        }

        let parsed = try JSONDecoder().decode(GraphCalendarViewResponse.self, from: data)
        let allEvents = parsed.value.compactMap { $0.toCalendarEvent(userDomain: userDomain) }
        return allEvents.filter { Self.passesRSVPFilter($0.rsvpStatus, AppSettings.meetingRSVPFilter) }
    }

    // MARK: - Private helpers

    private func persistTokenResponse(data: Data, fallbackRefresh: String?) async throws -> GraphTokens {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let tr = try decoder.decode(GraphTokenResponse.self, from: data)
        let principal = tr.idTokenClaims?.upn
            ?? tr.idTokenClaims?.preferredUsername
            ?? tokens?.userPrincipal
        let new = GraphTokens(
            accessToken: tr.accessToken,
            refreshToken: tr.refreshToken ?? fallbackRefresh ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(tr.expiresIn)),
            userPrincipal: principal
        )
        try KeychainStore.setCodable(new, account: Self.tokensAccount)
        tokens = new
        return new
    }

    private func formEncoded(_ params: [String: String]) -> String {
        params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private func decodeOAuthError(_ data: Data) -> (code: String, description: String?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let err = try? decoder.decode(OAuthError.self, from: data) {
            return (err.error, err.errorDescription)
        }
        return ("unknown", String(data: data, encoding: .utf8))
    }

    private static func errorBody(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s.count > 400 ? String(s.prefix(400)) + "…" : s
        }
        return "(empty body)"
    }

    private static func passesRSVPFilter(_ status: String, _ filter: MeetingRSVPFilter) -> Bool {
        switch filter {
        case .acceptedOnly:
            return status == "accepted" || status == "organizer"
        case .acceptedAndTentative:
            return status == "accepted" || status == "organizer" || status == "tentativelyAccepted"
        case .all:
            return true
        }
    }
}

// MARK: - Token + ID-token DTOs

private struct GraphTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String?
    let idToken: String?

    var idTokenClaims: IdTokenClaims? {
        guard let idToken else { return nil }
        return IdTokenClaims.decode(jwt: idToken)
    }
}

private struct IdTokenClaims: Codable {
    let upn: String?
    let preferredUsername: String?

    enum CodingKeys: String, CodingKey {
        case upn
        case preferredUsername = "preferred_username"
    }

    static func decode(jwt: String) -> IdTokenClaims? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        // base64url to base64 padding
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let mod = payload.count % 4
        if mod > 0 { payload += String(repeating: "=", count: 4 - mod) }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(IdTokenClaims.self, from: data)
    }
}

private struct OAuthError: Codable {
    let error: String
    let errorDescription: String?
}

// MARK: - Calendar response DTOs

private struct GraphCalendarViewResponse: Codable {
    let value: [GraphEvent]
}

private struct GraphEvent: Codable {
    let id: String
    let iCalUId: String?
    let subject: String?
    let bodyPreview: String?
    let start: GraphDateTime
    let end: GraphDateTime
    let isAllDay: Bool?
    let organizer: GraphRecipient?
    let attendees: [GraphAttendee]?
    let responseStatus: GraphResponseStatus?
    let location: GraphLocation?
    let isOnlineMeeting: Bool?
    let onlineMeetingProvider: String?
    let createdDateTime: String?
    let lastModifiedDateTime: String?

    func toCalendarEvent(userDomain: String?) -> CalendarEvent? {
        guard let startDate = parseGraphDateTime(start),
              let endDate = parseGraphDateTime(end) else { return nil }

        let userDomainLC = userDomain?.lowercased()
        var seen = Set<String>()
        var domains: [String] = []
        for attendee in attendees ?? [] {
            guard let address = attendee.emailAddress?.address, address.contains("@") else { continue }
            guard let domain = address.split(separator: "@").last.map(String.init)?.lowercased() else { continue }
            if domain == userDomainLC { continue }
            if seen.insert(domain).inserted { domains.append(domain) }
        }

        let parsedCreated = createdDateTime.flatMap { parseISO8601($0) } ?? Date()
        let parsedUpdated = lastModifiedDateTime.flatMap { parseISO8601($0) } ?? parsedCreated

        let response = responseStatus?.response ?? "none"
        let isOrganizerSelf = (response == "organizer")
        let rsvp: String = isOrganizerSelf ? "organizer" : response

        return CalendarEvent(
            id: id,
            iCalUID: iCalUId,
            subject: subject ?? "",
            bodyPreview: bodyPreview,
            startAt: startDate,
            endAt: endDate,
            isAllDay: isAllDay ?? false,
            organizerEmail: organizer?.emailAddress?.address,
            organizerName: organizer?.emailAddress?.name,
            rsvpStatus: rsvp,
            isOnlineMeeting: isOnlineMeeting ?? false,
            onlineMeetingProvider: onlineMeetingProvider,
            attendeeDomainsCSV: domains.isEmpty ? nil : domains.joined(separator: ","),
            location: location?.displayName,
            verifiedAttended: false,
            customerID: nil,
            projectID: nil,
            createdAt: parsedCreated,
            updatedAt: parsedUpdated
        )
    }
}

private struct GraphDateTime: Codable {
    let dateTime: String
    let timeZone: String?
}

private struct GraphRecipient: Codable {
    let emailAddress: GraphEmailAddress?
}

private struct GraphAttendee: Codable {
    let emailAddress: GraphEmailAddress?
    let type: String?
    let status: GraphResponseStatus?
}

private struct GraphEmailAddress: Codable {
    let address: String?
    let name: String?
}

private struct GraphResponseStatus: Codable {
    let response: String?
    let time: String?
}

private struct GraphLocation: Codable {
    let displayName: String?
}

private func parseGraphDateTime(_ dt: GraphDateTime) -> Date? {
    parseISO8601(dt.dateTime)
}

private func parseISO8601(_ raw: String) -> Date? {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: raw) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    if let d = f2.date(from: raw) { return d }
    // Graph sometimes returns "2026-05-12T13:00:00.0000000" without trailing Z
    let trimmed = raw.contains("T") && !raw.hasSuffix("Z") ? raw + "Z" : raw
    return f1.date(from: trimmed) ?? f2.date(from: trimmed)
}
