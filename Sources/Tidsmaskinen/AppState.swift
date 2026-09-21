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
    /// When set, the Review screen jumps to this week on its next appear/change
    /// (then clears it). Lets the menu-bar glance send you straight to the
    /// oldest week that still has unattributed items.
    @Published var reviewTargetWeekStart: Date?
    @Published var showSignIn: Bool = false
    /// True until the stored Microsoft identity has been looked up at launch,
    /// so the health check doesn't report "signed out" for the first second.
    @Published private(set) var isRestoringSignIn: Bool = true
    /// Set by the tray to open Settings on a specific pane; SettingsView consumes it.
    @Published var settingsTarget: SettingsCategory?

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
    let health: CaptureHealth
    let updaterController: SPUStandardUpdaterController

    // Rolling review backlog shared by the menu-bar glance and Review's landing
    // week. One pass resolves every sample of the last five weeks, so it is
    // refreshed at most every `reviewBacklogMaxAge` instead of on every 15 s
    // sample, and invalidated by Review's own writes and by calendar syncs.
    // Writes from Discover, Timeline and Calls fall back to the max age.
    @Published private(set) var reviewBacklog: ReviewQueue.Rolling?
    private var reviewBacklogComputedAt: Date?
    private var reviewBacklogTask: Task<ReviewQueue.Rolling, Error>?
    /// Bumped on invalidation so a computation started before a write can
    /// neither be stored nor joined afterwards.
    private var reviewBacklogGeneration = 0
    static let reviewBacklogMaxAge: TimeInterval = 5 * 60

    /// Sparkle asserts if the updater is started twice, and SwiftUI can build
    /// AppState more than once, so each instance tracks its own controller.
    private var updaterStarted: Bool
    private var cancellables = Set<AnyCancellable>()

    /// Starts the held-back Sparkle updater, once.
    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        updaterStarted = true
        updaterController.startUpdater()
    }
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
        // A pending relocation holds the updater back: an update that installs
        // while the user is still approving the move would be writing into the
        // bundle that is about to be replaced. AppRelocator broadcasts once it
        // knows the app is staying put.
        let holdUpdater = AppRelocator.shouldHoldUpdater
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: !holdUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterStarted = !holdUpdater
        self.health = CaptureHealth(database: database, calendarSync: calendarSync)

        // Every instance listens: the transient ones are discarded, and the
        // retained one must not be left with a stopped updater.
        NotificationCenter.default.publisher(for: AppRelocator.didSettle)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startUpdaterIfNeeded() }
            .store(in: &cancellables)

        health.isSignedIn = { [weak self] in self?.signedInPrincipal != nil }
        health.isRestoringSignIn = { [weak self] in self?.isRestoringSignIn ?? false }
        health.isCallDetectionRunning = { [weak self] in self?.micMonitor.isPolling ?? false }
        health.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward nested ObservableObject changes so views observing AppState
        // (e.g. MenuBarView, CalendarView) repaint when sync state changes.
        calendarSync.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        calendarSync.$lastSyncedAt
            .dropFirst()
            .sink { [weak self] _ in
                self?.invalidateReviewBacklog()
                self?.health.probe()
            }
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
        self.health.start()

        // Restore signed-in identity (best-effort, non-blocking).
        Task { @MainActor in
            if await graph.isSignedIn {
                signedInPrincipal = await graph.signedInPrincipal
                calendarSync.startAutoSync()
            }
            isRestoringSignIn = false
            health.probe()   // the first probe ran before identity was restored
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
        health.probe()
    }

    var isSignedIn: Bool {
        signedInPrincipal != nil
    }

    func signOut() async {
        await graph.signOut()
        signedInPrincipal = nil
        calendarSync.stopAutoSync()
        health.probe()
    }

    // MARK: - Review backlog

    /// Drops the cached rolling backlog so the next read recomputes it. An
    /// in-flight computation read the database before this write, so it is
    /// detached from the cache too; its result is discarded when it lands.
    func invalidateReviewBacklog() {
        reviewBacklogComputedAt = nil
        reviewBacklogGeneration += 1
        reviewBacklogTask = nil
    }

    /// The rolling backlog, recomputed off the main actor when the cache is
    /// missing, stale or invalidated. Concurrent callers share one computation.
    func currentReviewBacklog() async throws -> ReviewQueue.Rolling {
        if let cached = reviewBacklog, let at = reviewBacklogComputedAt,
           Date().timeIntervalSince(at) < Self.reviewBacklogMaxAge {
            return cached
        }
        if let task = reviewBacklogTask { return try await task.value }
        let generation = reviewBacklogGeneration
        let db = database
        let now = Date()
        let sampleInterval = AppSettings.sampleIntervalSeconds
        let idleSeconds = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
        let minMinutes = AppSettings.reviewMinMinutes
        let task = Task.detached(priority: .utility) {
            try ReviewQueue.rolling(
                database: db, now: now, weeksBack: ReviewQueue.defaultBacklogWeeksBack,
                sampleIntervalSeconds: sampleInterval,
                idleThresholdSeconds: idleSeconds,
                minMinutes: minMinutes)
        }
        reviewBacklogTask = task
        defer { if reviewBacklogGeneration == generation { reviewBacklogTask = nil } }
        let result = try await task.value
        guard reviewBacklogGeneration == generation else {
            // A write landed while we computed. Recompute rather than hand
            // back a snapshot that predates it.
            return try await currentReviewBacklog()
        }
        reviewBacklog = result
        reviewBacklogComputedAt = Date()
        return result
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
            invalidateReviewBacklog()
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
