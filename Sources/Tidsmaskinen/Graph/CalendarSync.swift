import Foundation
import Combine

@MainActor
final class CalendarSync: ObservableObject {
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetchedCount: Int = 0
    @Published private(set) var lastDeletedCount: Int = 0

    let database: AppDatabase
    let client: GraphClient

    private static let lastSyncedKey = "calendarSync.lastSyncedAt"
    private var autoSyncTimer: Timer?
    private var autoSyncObserver: NSObjectProtocol?

    init(database: AppDatabase, client: GraphClient) {
        self.database = database
        self.client = client
        self.lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date

        // Re-arm whenever the configured interval changes (or any setting).
        autoSyncObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rearmAutoSync() }
        }
    }

    deinit {
        autoSyncTimer?.invalidate()
        if let observer = autoSyncObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Start (or restart) the auto-sync timer at the user-configured interval.
    /// Safe to call multiple times. Fires an immediate sync first.
    func startAutoSync(initialSync: Bool = true) {
        rearmAutoSync()
        if initialSync {
            Task { await syncNow() }
        }
    }

    func stopAutoSync() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
    }

    private func rearmAutoSync() {
        let minutes = AppSettings.calendarAutoSyncMinutes
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
        guard minutes > 0 else { return }
        let interval = TimeInterval(minutes) * 60
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        autoSyncTimer = t
    }

    /// Manual sync: diff fetched against existing in range, delete orphans, preserve manual overrides.
    func syncNow(since: Date? = nil, until: Date? = nil) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let now = Date()
            let start = since ?? Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
            let end = until ?? Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
            let interval = DateInterval(start: start, end: end)

            let fetched = try await client.fetchCalendarView(start: start, end: end)
            let fetchedIDs = Set(fetched.map { $0.id })

            let existing = try database.calendarEvents(in: interval)
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            // Preserve manual overrides on surviving events.
            let merged = fetched.map { fresh -> CalendarEvent in
                guard let prior = existingByID[fresh.id] else { return fresh }
                var copy = fresh
                copy.customerID = prior.customerID
                copy.projectID = prior.projectID
                copy.verifiedAttended = prior.verifiedAttended
                return copy
            }
            try database.upsertEvents(merged)

            // Delete events in range that no longer exist on the server.
            let orphans = existing.filter { !fetchedIDs.contains($0.id) }
            for orphan in orphans {
                try database.deleteCalendarEvent(id: orphan.id)
            }

            lastFetchedCount = fetched.count
            lastDeletedCount = orphans.count
            lastSyncedAt = Date()
            UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncedKey)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }
}
