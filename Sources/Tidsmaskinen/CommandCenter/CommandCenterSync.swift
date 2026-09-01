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
        async let clientsTask = client.listClients()
        async let projectsTask = client.listProjects()
        let (ccClients, ccProjects) = try await (clientsTask, projectsTask)
        let result = try reconcile(clients: ccClients, projects: ccProjects)
        AppSettings.setCommandCenterLastSyncAt(result.finishedAt)
        return result
    }

    /// The DB half of a sync pass, split out from the fetch so it is testable
    /// without a network or a keychain token.
    func reconcile(
        clients ccClients: [CommandCenter.Client],
        projects ccProjects: [CommandCenter.Project]
    ) throws -> CommandCenterSyncResult {
        var result = CommandCenterSyncResult(startedAt: Date(), finishedAt: Date())
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

        var keptClientIDs = Set(ccClients.map { $0.id })

        // ---- Projects
        var keptProjectIDs = Set<String>()
        for cc in ccProjects {
            // Closed engagements fall out of keptProjectIDs and archive below —
            // the rules and reports pointing at them must still resolve.
            if cc.status == "closed" { continue }

            // A project can only land in our DB if its parent client also did.
            // `/planning/clients?status=active` hides prospect/inactive clients,
            // so adopt the parent from the engagement's own joined clientName
            // rather than dropping the engagement — otherwise a preliminary deal
            // on a not-yet-active client is invisible in Tidsmaskinen.
            guard let clientId = cc.clientId else { continue }
            let parentLookup: Customer?
            if let cached = customerByExternalID[clientId] {
                parentLookup = cached
            } else {
                parentLookup = try database.customer(externalSource: .commandCenter, externalID: clientId)
            }
            let parent: Customer
            if let found = parentLookup {
                parent = found
            } else if let clientName = cc.clientName {
                let adopted = Customer(
                    id: UUID().uuidString,
                    name: clientName,
                    color: nil,
                    createdAt: now,
                    externalSource: ExternalSource.commandCenter.rawValue,
                    externalID: clientId,
                    externalSyncedAt: now
                )
                try database.upsert(adopted)
                customerByExternalID[clientId] = adopted
                result.clientsImported += 1
                parent = adopted
            } else {
                continue
            }
            keptClientIDs.insert(clientId)
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

        // After the project loop: keptClientIDs now also holds clients adopted
        // via an engagement, which must not be archived back out.
        result.clientsArchived = try database.archiveMissingCustomers(
            source: .commandCenter,
            keepingExternalIDs: keptClientIDs
        )

        result.finishedAt = Date()
        return result
    }
}
