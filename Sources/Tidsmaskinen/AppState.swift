import Foundation
import Combine
import GRDB

@MainActor
final class AppState: ObservableObject {
    @Published var latestSample: ActivitySample?
    @Published var sampleCount: Int = 0
    @Published var startedAt: Date = Date()
    @Published var lastError: String?
    @Published var signedInPrincipal: String?

    let database: AppDatabase
    let monitor: ActivityMonitor
    let graph: GraphClient
    let calendarSync: CalendarSync
    let hookIngester: HookIngester
    let claudeAPI: ClaudeAPI
    let micMonitor: MicMonitor

    private var cancellables = Set<AnyCancellable>()

    init() {
        do {
            self.database = try AppDatabase.shared()
        } catch {
            fatalError("Failed to open database: \(error)")
        }
        self.monitor = ActivityMonitor(database: database)
        self.graph = GraphClient()
        self.calendarSync = CalendarSync(database: database, client: graph)
        self.hookIngester = HookIngester(database: database)
        self.claudeAPI = ClaudeAPI()
        self.micMonitor = MicMonitor(database: database)

        // Forward nested ObservableObject changes so views observing AppState
        // (e.g. MenuBarView, CalendarView) repaint when sync state changes.
        calendarSync.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        self.monitor.onSample = { [weak self] sample in
            Task { @MainActor in
                self?.latestSample = sample
                self?.sampleCount += 1
            }
        }
        self.monitor.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
            }
        }
        self.monitor.start()
        self.hookIngester.start()
        self.micMonitor.onSessionStart = { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        self.micMonitor.onSessionEnd = { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        self.micMonitor.start()

        // Restore signed-in identity (best-effort, non-blocking).
        Task { @MainActor in
            if await graph.isSignedIn {
                signedInPrincipal = await graph.signedInPrincipal
                calendarSync.startAutoSync()
            }
        }
    }

    func didSignIn(principal: String) {
        signedInPrincipal = principal
        calendarSync.startAutoSync()
    }

    var isSignedIn: Bool {
        signedInPrincipal != nil
    }

    func signOut() async {
        await graph.signOut()
        signedInPrincipal = nil
        calendarSync.stopAutoSync()
    }
}
