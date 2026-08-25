import Foundation

/// Wire types matching the relevant subset of command-center's
/// `packages/api-client/src/client.ts`. We only decode the fields tidsmaskinen
/// uses for picker population — `actualHours`, `assignmentCount`, budgets,
/// owners, etc. are dropped on the floor.
enum CommandCenter {
    struct Client: Codable, Equatable, Hashable {
        let id: String
        let name: String
        let status: String          // "active" | "prospect" | "inactive"
    }

    struct Project: Codable, Equatable, Hashable {
        let id: String
        let name: String
        let clientId: String?
        let engagementType: String  // "retainer" | "project_fixed" | "project_tnm" | "internal"
        let status: String
        let color: String?

        enum CodingKeys: String, CodingKey {
            case id, name, clientId, status, color
            case engagementType = "type"
        }
    }

    struct ListClientsResponse: Codable {
        let clients: [Client]
    }
}
