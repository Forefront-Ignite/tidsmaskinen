import Foundation

/// Read-only client for the Command Center backend's planning endpoints.
/// All requests carry a Bearer token resolved at call time so the user can
/// rotate it via Settings without restarting the actor.
actor CommandCenterClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    /// `GET /planning/clients?status=active`
    func listClients() async throws -> [CommandCenter.Client] {
        let response: CommandCenter.ListClientsResponse =
            try await get(path: "/planning/clients", query: ["status": "active"])
        return response.clients
    }

    /// `GET /planning/engagements` — CC renamed projects to engagements and now
    /// returns a bare array. Deliberately *unfiltered*: CC labels a `planned`
    /// engagement "Preliminär", and preliminary work is still work you report
    /// time on, so it belongs in the picker. `closed` is dropped in `reconcile`
    /// instead, where it archives rather than disappears.
    func listProjects() async throws -> [CommandCenter.Project] {
        try await get(path: "/planning/engagements")
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        guard let token = CommandCenterAuth.loadToken() else {
            throw CommandCenterError.missingToken
        }

        let base = AppSettings.commandCenterBaseURL
        guard var components = URLComponents(string: base) else {
            throw CommandCenterError.transport("Invalid base URL: \(base)")
        }
        components.path = (components.path + path).replacingOccurrences(of: "//", with: "/")
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw CommandCenterError.transport("Could not assemble URL from \(base) + \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CommandCenterError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CommandCenterError.transport("Non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw CommandCenterError.decoding(String(describing: error))
            }
        case 401:
            throw CommandCenterError.unauthorized
        case 403:
            throw CommandCenterError.forbidden
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CommandCenterError.http(status: http.statusCode, body: body)
        }
    }
}
