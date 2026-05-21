import Foundation
import AppKit
import CoreGraphics

@MainActor
final class ActivityMonitor {
    private let database: AppDatabase
    private var timer: Timer?
    private var isPaused = false
    private let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    private var currentInterval: TimeInterval = 0
    // Read in deinit-style teardown paths; mutated only on MainActor.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    var onSample: ((ActivitySample) -> Void)?
    var onError: ((Error) -> Void)?

    init(database: AppDatabase) {
        self.database = database
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)

        captureNow()
        rescheduleTimer()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification queue runs on the main thread (queue: .main)
            // but the closure is @Sendable; hop explicitly so the compiler
            // can see we're back on the actor.
            Task { @MainActor [weak self] in
                self?.rescheduleTimer()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
    }

    private func rescheduleTimer() {
        let desired = TimeInterval(AppSettings.sampleIntervalSeconds)
        if desired == currentInterval, timer != nil { return }
        timer?.invalidate()
        let t = Timer(timeInterval: desired, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureNow()
            }
        }
        t.tolerance = max(1, desired * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        currentInterval = desired
    }

    @objc private func handleSleep() {
        isPaused = true
    }

    @objc private func handleWake() {
        isPaused = false
        captureNow()
    }

    private func captureNow() {
        guard !isPaused else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        // Don't track ourselves.
        if frontmost.processIdentifier == ownPID { return }

        let idleSeconds = Self.idleSeconds()
        let isIdle = idleSeconds > TimeInterval(AppSettings.idleThresholdSeconds)

        let bundleID = frontmost.bundleIdentifier
        let pid = frontmost.processIdentifier

        let title = isIdle ? nil : Probes.windowTitle(pid: pid)

        var chromeURL: String?
        var chromeHost: String?
        // Only probe Chrome's URL when Chrome is actually frontmost — the
        // AppleScript targets "Google Chrome" specifically, so running it for
        // Brave/Arc/etc. would (a) trigger Chrome's Automation prompt and
        // (b) return a URL from a backgrounded Chrome window.
        if !isIdle, bundleID == Probes.chromeBundleID {
            chromeURL = Probes.chromeActiveTabURL()
            chromeHost = chromeURL.flatMap(Probes.host(for:))
        }

        var repoPath: String?
        var remoteURL: String?
        if !isIdle, let id = bundleID, Probes.codeEditorBundleIDs.contains(id) {
            if let docPath = Probes.windowDocumentPath(pid: pid),
               let root = Probes.findGitRoot(near: docPath) {
                repoPath = root
                remoteURL = Probes.gitOriginURL(repoRoot: root)
            }
        }

        let sample = ActivitySample(
            id: nil,
            capturedAt: Date(),
            appBundleID: bundleID,
            appName: frontmost.localizedName,
            windowTitle: title,
            chromeURL: chromeURL,
            chromeHost: chromeHost,
            gitRepoPath: repoPath,
            gitRemoteURL: remoteURL,
            isIdle: isIdle
        )

        do {
            let saved = try database.insert(sample)
            onSample?(saved)
        } catch {
            onError?(error)
        }
    }

    private static func idleSeconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}
