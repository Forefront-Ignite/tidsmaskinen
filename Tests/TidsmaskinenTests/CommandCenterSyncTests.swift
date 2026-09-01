import XCTest
@testable import Tidsmaskinen

/// `/planning/clients?status=active` only returns active clients, but
/// `/planning/engagements` returns every engagement regardless of status —
/// including preliminary (`planned`) deals that may hang off a client the
/// active-only client list never mentioned. Those engagements used to be
/// dropped as orphans; they are now adopted via the engagement's `clientName`.
@MainActor
final class CommandCenterSyncTests: XCTestCase {
    private func project(
        id: String,
        name: String,
        clientId: String?,
        clientName: String?,
        status: String = "planned"
    ) -> CommandCenter.Project {
        CommandCenter.Project(
            id: id,
            name: name,
            clientId: clientId,
            clientName: clientName,
            engagementType: "project_fixed",
            status: status,
            color: nil
        )
    }

    func testAdoptsClientMissingFromActiveClientList() async throws {
        let db = try AppDatabase.inMemoryForTesting()
        let sync = CommandCenterSync(database: db, client: CommandCenterClient())

        let result = try await sync.reconcile(
            clients: [],  // Ambea is not `status=active` upstream
            projects: [project(id: "e1", name: "Årshjulet/Stödhjulet", clientId: "c1", clientName: "Ambea")]
        )

        XCTAssertEqual(result.projectsImported, 1)
        XCTAssertEqual(try db.allCustomers().map(\.name), ["Ambea"])
        XCTAssertEqual(try db.allProjects().map(\.name), ["Årshjulet/Stödhjulet"])
    }

    /// The adopted customer must survive the archive pass that runs in the same
    /// sync — it is absent from the fetched client list by definition.
    func testAdoptedClientIsNotArchivedBySameSync() async throws {
        let db = try AppDatabase.inMemoryForTesting()
        let sync = CommandCenterSync(database: db, client: CommandCenterClient())
        let engagements = [project(id: "e1", name: "Årshjulet/Stödhjulet", clientId: "c1", clientName: "Ambea")]

        _ = try await sync.reconcile(clients: [], projects: engagements)
        let second = try await sync.reconcile(clients: [], projects: engagements)

        XCTAssertEqual(second.clientsArchived, 0)
        XCTAssertEqual(second.projectsArchived, 0)
        XCTAssertEqual(try db.allCustomers().count, 1)
        XCTAssertEqual(try db.allProjects().count, 1)
    }

    /// The reported bug: CC labels a `planned` engagement "Preliminär"; it used
    /// to be filtered out of the fetch entirely. Closed work still archives.
    func testPreliminaryEngagementSyncsAndClosedOneArchives() async throws {
        let db = try AppDatabase.inMemoryForTesting()
        let sync = CommandCenterSync(database: db, client: CommandCenterClient())
        let ambea = CommandCenter.Client(id: "c1", name: "Ambea", status: "active")

        let result = try await sync.reconcile(
            clients: [ambea],
            projects: [
                project(id: "e1", name: "Årshjulet/Stödhjulet", clientId: "c1", clientName: "Ambea", status: "planned"),
                project(id: "e2", name: "Robot api", clientId: "c1", clientName: "Ambea", status: "active"),
                project(id: "e3", name: "Vardaga app", clientId: "c1", clientName: "Ambea", status: "closed"),
            ]
        )

        XCTAssertEqual(result.projectsImported, 2)
        XCTAssertEqual(try db.allProjects().map(\.name).sorted(), ["Robot api", "Årshjulet/Stödhjulet"])
        XCTAssertFalse(try db.allProjectsIncludingArchived().contains { $0.name == "Vardaga app" && $0.externalSource == ExternalSource.commandCenter.rawValue })
    }

    /// No client at all is still unattributable — nothing sane to hang it off.
    func testEngagementWithoutClientIsStillSkipped() async throws {
        let db = try AppDatabase.inMemoryForTesting()
        let sync = CommandCenterSync(database: db, client: CommandCenterClient())

        let result = try await sync.reconcile(
            clients: [],
            projects: [project(id: "e1", name: "Orphan", clientId: nil, clientName: nil)]
        )

        XCTAssertEqual(result.projectsImported, 0)
        XCTAssertTrue(try db.allProjects().isEmpty)
    }
}
