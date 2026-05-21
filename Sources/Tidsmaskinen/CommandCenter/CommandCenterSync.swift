import Foundation

/// Result of one sync pass — used by Settings UI to show counts and errors.
struct CommandCenterSyncResult: Equatable {
    var clientsImported: Int = 0
    var clientsUpdated: Int = 0
    var clientsArchived: Int = 0
    var projectsImported: Int = 0
    var projectsUpdated: Int = 0
    var projectsArchived: Int = 0
    var startedAt: Date = Date()
    var finishedAt: Date = Date()

    var totalChanges: Int {
        clientsImported + clientsUpdated + clientsArchived +
        projectsImported + projectsUpdated + projectsArchived
    }
}

/// Pulls Command Center clients + projects and reconciles them with the local
/// `customers` / `projects` tables. External rows that disappear upstream get
/// flipped to the archived flavor rather than deleted — historical rules,
/// reports, and attribution rows referencing them must still resolve.
actor CommandCenterSync {
    private let database: AppDatabase
    private let client: CommandCenterClient

    init(database: AppDatabase, client: CommandCenterClient) {
        self.database = database
        self.client = client
    }

    func runSync() async throws -> CommandCenterSyncResult {
        var result = CommandCenterSyncResult(startedAt: Date(), finishedAt: Date())

        async let clientsTask = client.listClients()
        async let projectsTask = client.listProjects()
        let (ccClients, ccProjects) = try await (clientsTask, projectsTask)

        let now = Date()
        var customerByExternalID: [String: Customer] = [:]

        // ---- Customers (CC "clients" → local "customers")
        for cc in ccClients {
            if var existing = try database.customer(externalSource: .commandCenter, externalID: cc.id) {
                var didChange = false
                if existing.name != cc.name { existing.name = cc.name; didChange = true }
                // Resurrect rows that were previously archived but came back upstream.
                if existing.externalSource != ExternalSource.commandCenter.rawValue {
                    existing.externalSource = ExternalSource.commandCenter.rawValue
                    didChange = true
                }
                existing.externalSyncedAt = now
                try database.upsert(existing)
                customerByExternalID[cc.id] = existing
                if didChange { result.clientsUpdated += 1 }
            } else {
                let new = Customer(
                    id: UUID().uuidString,
                    name: cc.name,
                    color: nil,
                    createdAt: now,
                    externalSource: ExternalSource.commandCenter.rawValue,
                    externalID: cc.id,
                    externalSyncedAt: now
                )
                try database.upsert(new)
                customerByExternalID[cc.id] = new
                result.clientsImported += 1
            }
        }

        let keptClientIDs = Set(ccClients.map { $0.id })
        result.clientsArchived = try database.archiveMissingCustomers(
            source: .commandCenter,
            keepingExternalIDs: keptClientIDs
        )

        // ---- Projects
        var keptProjectIDs = Set<String>()
        for cc in ccProjects {
            // A project can only land in our DB if its parent client also did.
            // Skip orphans rather than inventing a stub customer.
            guard let clientId = cc.clientId else { continue }
            let parentLookup: Customer?
            if let cached = customerByExternalID[clientId] {
                parentLookup = cached
            } else {
                parentLookup = try database.customer(externalSource: .commandCenter, externalID: clientId)
            }
            guard let parent = parentLookup else { continue }
            keptProjectIDs.insert(cc.id)

            if var existing = try database.project(externalSource: .commandCenter, externalID: cc.id) {
                var didChange = false
                if existing.name != cc.name { existing.name = cc.name; didChange = true }
                if existing.customerID != parent.id { existing.customerID = parent.id; didChange = true }
                if existing.engagementType != cc.engagementType {
                    existing.engagementType = cc.engagementType
                    didChange = true
                }
                if existing.externalColor != cc.color {
                    existing.externalColor = cc.color
                    didChange = true
                }
                if existing.externalSource != ExternalSource.commandCenter.rawValue {
                    existing.externalSource = ExternalSource.commandCenter.rawValue
                    didChange = true
                }
                existing.externalSyncedAt = now
                try database.upsert(existing)
                if didChange { result.projectsUpdated += 1 }
            } else {
                let new = Project(
                    id: UUID().uuidString,
                    customerID: parent.id,
                    name: cc.name,
                    color: nil,
                    createdAt: now,
                    externalSource: ExternalSource.commandCenter.rawValue,
                    externalID: cc.id,
                    externalSyncedAt: now,
                    engagementType: cc.engagementType,
                    externalColor: cc.color
                )
                try database.upsert(new)
                result.projectsImported += 1
            }
        }

        result.projectsArchived = try database.archiveMissingProjects(
            source: .commandCenter,
            keepingExternalIDs: keptProjectIDs
        )

        result.finishedAt = Date()
        AppSettings.setCommandCenterLastSyncAt(result.finishedAt)
        return result
    }
}
