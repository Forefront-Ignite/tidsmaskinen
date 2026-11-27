import AppKit
@preconcurrency import UserNotifications

/// Live verification of everything the weekly report depends on. Every check
/// is probed functionally — a real trust call, a real Apple event, a real file
/// date — never read from a cached grant, because a grant can be revoked
/// silently (and macOS 26 can hide the menu-bar item outside Privacy &
/// Security). Probed every minute, on activation, and whenever the tray or
/// the Setup pane opens. A capture permission that flips from working to
/// failed posts one notification; calendar staleness only shows in the UI.
@MainActor
final class CaptureHealth: ObservableObject {
    enum Check: String, CaseIterable, Identifiable {
        case accessibility, chrome, agentFocus, calendar, cells, hooks, menuBar, customers
        var id: String { rawValue }

        /// Short label for the tray stripe.
        var label: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .chrome:        return "Chrome"
            case .agentFocus:    return "Claude focus"
            case .calendar:      return "Calendar"
            case .cells:         return "Cells"
            case .hooks:         return "Hooks"
            case .menuBar:       return "Menu bar"
            case .customers:     return "Customers"
            }
        }

        /// What the check secures, for the Setup pane.
        var purpose: String {
            switch self {
            case .accessibility: return "window titles and repos"
            case .chrome:        return "tab URLs (Chrome automation)"
            case .agentFocus:    return "which Claude Code session you have in front"
            case .calendar:      return "meetings from Microsoft 365"
            case .cells:         return "your Cells calls and which Cell a chat belongs to"
            case .hooks:         return "Claude Code and Codex sessions"
            case .menuBar:       return "the icon macOS can hide"
            case .customers:     return "somewhere for time to land"
            }
        }
    }

    enum Level: Int, Comparable {
        case ok, off, warn, fail
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Status: Equatable {
        let level: Level
        let detail: String
        let checkedAt: Date
    }

    @Published private(set) var statuses: [Check: Status] = [:]
    @Published private(set) var lastProbeAt: Date?

    private let database: AppDatabase
    private let calendarSync: CalendarSync
    /// Set by AppState once it exists (they read its state).
    var isSignedIn: () -> Bool = { false }
    /// True while the stored Microsoft identity is still being restored at launch.
    var isRestoringSignIn: () -> Bool = { false }
    /// When Claude's log was last read (nil: unreadable) and the newest
    /// session switch stored from it.
    var agentFocusState: () -> (lastReadAt: Date?, latestEventAt: Date?) = { (nil, nil) }
    struct CellsState { let hasToken: Bool; let tokenInvalid: Bool; let lastSyncAt: Date?; let lastError: String? }
    var cellsState: () -> CellsState = { .init(hasToken: false, tokenInvalid: false, lastSyncAt: nil, lastError: nil) }
    private var timer: Timer?
    private var notified: Set<Check> = []

    init(database: AppDatabase, calendarSync: CalendarSync) {
        self.database = database
        self.calendarSync = calendarSync
    }

    func start() {
        guard timer == nil else { return }
        probe()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
    }

    func status(_ check: Check) -> Status {
        statuses[check] ?? Status(level: .off, detail: "not checked yet", checkedAt: .distantPast)
    }

    var hasFailure: Bool { statuses.values.contains { $0.level == .fail } }

    /// Checks that still need the user: warnings and failures.
    var openStepCount: Int { statuses.values.filter { $0.level >= .warn }.count }

    /// "Capturing" / "Partly capturing": what the foreground sampler can see right now.
    var captureLabel: String {
        let capture: [Check] = [.accessibility, .chrome]
        return capture.contains { status($0).level == .fail } ? "Partly capturing" : "Capturing"
    }

    func probe(now: Date = Date()) {
        var next: [Check: Status] = [:]
        func set(_ c: Check, _ level: Level, _ detail: String) {
            next[c] = Status(level: level, detail: detail, checkedAt: now)
        }

        let trusted = Probes.isAccessibilityTrusted(promptIfNeeded: false)
        set(.accessibility, trusted ? .ok : .fail,
            trusted ? "window titles and repos are being read" : "not granted — window titles and repos aren't recorded")

        if !Probes.isChromeRunning() {
            set(.chrome, .off, "Chrome isn't running")
        } else {
            switch Probes.requestAutomationPermission(forBundle: Probes.chromeBundleID, prompt: false) {
            case .granted:          set(.chrome, .ok, "a real Apple event succeeded")
            case .denied:           set(.chrome, .fail, "automation denied — tab URLs aren't recorded")
            case .targetNotRunning: set(.chrome, .off, "Chrome isn't running")
            case .unknown(let s):   set(.chrome, .warn, "not asked yet (OSStatus \(s)) — request access")
            }
        }

        // Claude's own log names the Code session in front. Undocumented, so
        // verify it is still readable and still saying something.
        let claude = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeFocusLog.bundleID).first
        let focus = agentFocusState()
        if claude == nil {
            set(.agentFocus, .off, "Claude isn't running")
        } else if focus.lastReadAt == nil {
            set(.agentFocus, .warn, "Claude's log can't be read — time in Claude keeps no session")
        } else if let launched = claude?.launchDate,
                  (focus.latestEventAt ?? .distantPast) < launched.addingTimeInterval(-2) {
            if now.timeIntervalSince(launched) > 120 {
                set(.agentFocus, .warn, "no session switch read since Claude started — its log may have changed")
            } else {
                set(.agentFocus, .off, "waiting for Claude to open a session")
            }
        } else if let last = focus.latestEventAt {
            set(.agentFocus, .ok, "last session switch \(Self.age(now.timeIntervalSince(last))) ago")
        } else {
            set(.agentFocus, .ok, "reading Claude's log")
        }

        if isRestoringSignIn() {
            set(.calendar, .off, "checking the Microsoft sign-in…")
        } else if !isSignedIn() {
            set(.calendar, .fail, "signed out — meetings aren't imported")
        } else if let err = calendarSync.lastError {
            set(.calendar, .warn, "last sync failed: \(err)")
        } else if let at = calendarSync.lastSyncedAt {
            let age = now.timeIntervalSince(at)
            let staleAfter = TimeInterval(AppSettings.calendarStaleDays) * 86_400
            set(.calendar, age > staleAfter ? .warn : .ok,
                age > staleAfter ? "last synced \(Self.age(age)) ago — meetings since then are missing"
                                 : "synced \(Self.age(age)) ago")
        } else {
            set(.calendar, .warn, "signed in, not synced yet")
        }

        let cells = cellsState()
        if !cells.hasToken {
            set(.cells, .off, "not connected — paste a Cells token in Settings to count Cells calls")
        } else if cells.tokenInvalid {
            set(.cells, .warn, "token rejected — paste a new one in Settings")
        } else if let err = cells.lastError {
            set(.cells, .warn, "last sync failed: \(err)")
        } else if let at = cells.lastSyncAt {
            let age = now.timeIntervalSince(at)
            set(.cells, age > 3 * 3600 ? .warn : .ok,
                age > 3 * 3600 ? "last synced \(Self.age(age)) ago" : "synced \(Self.age(age)) ago")
        } else {
            set(.cells, .off, "not synced yet")
        }

        let hookStates = CodingAgentProvider.allCases.map { ($0, HookInstaller.currentState(provider: $0)) }
        let installed = hookStates.compactMap { p, s -> String? in
            if case .installed = s { return p.displayName } else { return nil }
        }
        let stale = hookStates.compactMap { p, s -> String? in
            if case .stale = s { return p.displayName } else { return nil }
        }
        if !stale.isEmpty {
            set(.hooks, .warn, "\(stale.joined(separator: " and ")) hook points at an old build — reinstall")
        } else if installed.isEmpty {
            set(.hooks, .warn, "not installed — coding sessions aren't recorded")
        } else {
            var detail = "\(installed.joined(separator: " and ")) installed"
            if let last = Self.lastHookEventAt() { detail += " · last event \(Self.age(now.timeIntervalSince(last))) ago" }
            set(.hooks, .ok, detail)
        }

        // Ordered in with a width, not occlusion: a full-screen app, an
        // auto-hidden menu bar or the lock screen occlude a perfectly good item.
        if let bar = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") }) {
            let shown = bar.isVisible && bar.frame.width > 1
            set(.menuBar, shown ? .ok : .warn,
                shown ? "icon visible" : "icon may be hidden — macOS can hide it under System Settings › Menu Bar")
        } else {
            set(.menuBar, .off, "can't verify on this build")
        }

        let customers = (try? database.allCustomers()) ?? []
        let external = customers.filter(\.isExternal).count
        if customers.isEmpty {
            set(.customers, .warn, "none yet — add one under Customers or sync Command Center")
        } else {
            set(.customers, .ok, "\(customers.count) customers" + (external > 0 ? " · \(external) from Command Center" : ""))
        }

        for check in [Check.accessibility, .chrome] {
            let before = statuses[check]?.level, after = next[check]?.level
            if before == .ok, after == .fail, let st = next[check] { notify(check, st) }
            if after == .ok { notified.remove(check) }
        }
        statuses = next
        lastProbeAt = now
    }

    /// One notification per loss, and only for the capture permissions — a
    /// stale calendar waits behind the threshold in Settings and shows in the UI.
    private func notify(_ check: Check, _ status: Status) {
        guard Bundle.main.bundleIdentifier != nil, !notified.contains(check) else { return }
        notified.insert(check)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Tidsmaskinen stopped recording \(check == .accessibility ? "window titles" : "Chrome tabs")"
            content.body = status.detail
            center.add(UNNotificationRequest(identifier: "health-\(check.rawValue)", content: content, trigger: nil))
        }
    }

    private static func lastHookEventAt() -> Date? {
        guard let url = try? AppPaths.supportDirectory().appendingPathComponent(HookIngester.eventLogFilename),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    static func age(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "moments" }
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 48 { return "\(h) h" }
        return "\(h / 24) days"
    }

    /// Open a System Settings pane. The `x-apple.systempreferences:` scheme is
    /// undocumented and some panes broke in macOS 26, so fall back to opening
    /// System Settings plain rather than doing nothing.
    static func openSystemSettings(pane: String?) {
        if let pane, let url = URL(string: "x-apple.systempreferences:\(pane)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
