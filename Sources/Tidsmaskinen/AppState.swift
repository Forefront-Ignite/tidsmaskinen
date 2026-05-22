import Foundation
import Combine
import GRDB
import Sparkle

@MainActor
final class AppState: ObservableObject {
    @Published var latestSample: ActivitySample?
    @Published var sampleCount: Int = 0
    @Published var startedAt: Date = Date()
    @Published var lastError: String?
    @Published var signedInPrincipal: String?
    @Published var selectedSection: SidebarItem = .weeklyReport
    @Published var showSignIn: Bool = false

    // Command Center sync state — driven by `commandCenter.runSync()`.
    @Published var commandCenterLastSyncAt: Date? = AppSettings.commandCenterLastSyncAt
    @Published var commandCenterTokenInvalid: Bool = false
    @Published var commandCenterIsSyncing: Bool = false
    @Published var commandCenterLastError: String?
    @Published var commandCenterHasToken: Bool = CommandCenterAuth.loadToken() != nil

    let database: AppDatabase
    let monitor: ActivityMonitor
    let graph: GraphClient
    let calendarSync: CalendarSync
    let hookIngester: HookIngester
    let micMonitor: MicMonitor
    let commandCenter: CommandCenterClient
    let commandCenterSync: CommandCenterSync
    let updaterController: SPUStandardUpdaterController

    private var cancellables = Set<AnyCancellable>()
    private var commandCenterAutoSyncTask: Task<Void, Never>?

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
        self.micMonitor = MicMonitor(database: database)
        let ccClient = CommandCenterClient()
        self.commandCenter = ccClient
        self.commandCenterSync = CommandCenterSync(database: database, client: ccClient)
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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

        // Best-effort: try a sync on launch if we have a token + CC is enabled.
        if AppSettings.commandCenterEnabled, commandCenterHasToken {
            Task { @MainActor in
                await self.refreshCommandCenter()
            }
        }
        startCommandCenterAutoSync()
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

    // MARK: - Command Center

    /// Saves a new token and (best-effort) immediately re-syncs.
    func saveCommandCenterToken(_ token: String) {
        do {
            try CommandCenterAuth.saveToken(token)
            commandCenterHasToken = true
            commandCenterTokenInvalid = false
            commandCenterLastError = nil
            Task { @MainActor in await self.refreshCommandCenter() }
        } catch {
            commandCenterLastError = error.localizedDescription
        }
    }

    func clearCommandCenterToken() {
        CommandCenterAuth.clearToken()
        commandCenterHasToken = false
        commandCenterTokenInvalid = false
    }

    /// Triggers a sync immediately, surfacing errors on `commandCenterLastError`.
    /// No-op if a sync is already running.
    func refreshCommandCenter() async {
        guard !commandCenterIsSyncing else { return }
        guard AppSettings.commandCenterEnabled else { return }
        commandCenterIsSyncing = true
        defer { commandCenterIsSyncing = false }
        do {
            let result = try await commandCenterSync.runSync()
            commandCenterLastSyncAt = result.finishedAt
            commandCenterTokenInvalid = false
            commandCenterLastError = nil
            objectWillChange.send()
        } catch let error as CommandCenterError {
            commandCenterLastError = error.description
            if error.isAuthFailure { commandCenterTokenInvalid = true }
        } catch {
            commandCenterLastError = error.localizedDescription
        }
    }

    private func startCommandCenterAutoSync() {
        commandCenterAutoSyncTask?.cancel()
        commandCenterAutoSyncTask = Task { @MainActor [weak self] in
            // Hourly poll. Cheap — two GETs returning a few hundred rows.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(3600 * 1_000_000_000))
                guard let self else { return }
                guard AppSettings.commandCenterEnabled,
                      self.commandCenterHasToken,
                      !self.commandCenterTokenInvalid else { continue }
                await self.refreshCommandCenter()
            }
        }
    }
}
