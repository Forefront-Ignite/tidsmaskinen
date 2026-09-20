import AppKit
import Foundation

/// Moves the running app into `~/Applications` so Sparkle can update it
/// without an admin prompt.
///
/// Sparkle only installs without authorization when the bundle *and its parent
/// folder* are writable by the user and the bundle is owned by the user
/// (`SPUSystemNeedsAuthorizationAccessForBundlePath`). `/Applications` is
/// `root:admin`, so on a standard-user Mac (Admin By Request) every update
/// asks for admin rights. `~/Applications` is fully user-owned, so nothing
/// prompts there. The one-time move out of `/Applications` needs admin rights
/// itself; it runs via `do shell script … with administrator privileges`,
/// which uses the `system.privilege.admin` right that Admin By Request wraps,
/// so the user gets ABR's own request flow instead of a password prompt.
@MainActor
enum AppRelocator {
    static let userApplications = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)

    /// Starts the Sparkle updater once relocation is settled. `AppState` holds
    /// it back while a move is pending so an update can't install into — or
    /// replace — the bundle we are about to move, which an Admin By Request
    /// approval can leave in flight for minutes.
    static var startUpdater: (() -> Void)?

    /// True when `run()` would offer to move this install. Read by `AppState`
    /// before it builds the updater, and re-checked inside `run()`; nothing
    /// changes in between.
    static var isMovePending: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return false }
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension == "app"
            // Gatekeeper runs quarantined apps from a read-only mount; that
            // path can't be moved. The user has to drag the app out first.
            && !bundleURL.path.contains("/AppTranslocation/")
            && updatesNeedAdmin(bundleURL)
            && !AppSettings.defaults.bool(forKey: SettingsKey.relocationPromptSuppressed)
    }

    /// Call once the app has finished launching. Finishes a move made on the
    /// previous launch, then offers a move when Sparkle would need admin
    /// rights to update this install. Dev builds ship without `SUFeedURL` and
    /// are left alone. Every path that doesn't end in a relaunch releases the
    /// updater before returning.
    static func run() {
        finishPendingRelocation()
        guard isMovePending else { return releaseUpdater() }
        // Resolve symlinks before anything reaches a root shell: an
        // ~/Applications symlinked to /Applications would otherwise compare as
        // a different path, and the command would delete the running bundle
        // and chown a system folder.
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = userApplications.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        guard parent.path.hasPrefix(home.path + "/") else {
            showFailure("Can't move Tidsmaskinen automatically",
                        """
                        Your Applications folder leads to \(parent.path), outside your home folder, so \
                        moving there wouldn't stop the admin prompts.

                        Move Tidsmaskinen by hand into a folder you own instead.
                        """)
            return releaseUpdater()
        }
        let target = parent.appendingPathComponent(bundleURL.lastPathComponent)
        // Root is about to delete whatever sits at the destination, so refuse
        // anything that isn't plainly an older copy of this app.
        if let refusal = destinationRefusal(at: target,
                                            ourVersion: bundleVersion(of: Bundle.main),
                                            ourBundleID: Bundle.main.bundleIdentifier) {
            showFailure(refusal.title, refusal.detail)
            return releaseUpdater()
        }

        let alert = NSAlert()
        alert.messageText = "Move Tidsmaskinen to your Applications folder?"
        alert.informativeText = """
            Tidsmaskinen is installed in a folder only administrators can change, so every update \
            asks for admin rights. Moving it to ~/Applications fixes that for good.

            You'll be asked for admin rights one last time, then Tidsmaskinen relaunches.
            """
        alert.addButton(withTitle: "Move and Relaunch")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            // Only a declined prompt is worth remembering: a failed move should
            // be offered again next launch.
            if alert.suppressionButton?.state == .on {
                AppSettings.defaults.set(true, forKey: SettingsKey.relocationPromptSuppressed)
            }
            return releaseUpdater()
        }

        // The login item is tied to the bundle's inode and path. Drop it now
        // and re-register from the new location after relaunch.
        let hadLoginItem = LoginItemManager.isEnabled
        if hadLoginItem { try? LoginItemManager.setEnabled(false) }
        do {
            try move(bundleURL, to: target)
        } catch {
            // The error says what the Apple event reported; only the filesystem
            // says what happened. An event timeout can fire while the
            // privileged command goes on to complete, and treating that as a
            // cancellation would strand the login item and hooks on a bundle
            // that is no longer there.
            if !moveLanded(from: bundleURL, to: target, waitingUpTo: waitForMoveSeconds(after: error)) {
                defer { releaseUpdater() }
                if case RelocationError.cancelled = error {
                    if hadLoginItem { try? LoginItemManager.setEnabled(true) }
                    return
                }
                // The command may still be waiting on an approval and land
                // after we give up. Leave the repair pending so the next launch
                // repoints the login item and hooks either way; it is a no-op
                // when nothing moved after all.
                AppSettings.defaults.set(hadLoginItem, forKey: SettingsKey.relocationRestoreLoginItem)
                if hadLoginItem { try? LoginItemManager.setEnabled(true) }
                showFailure("Couldn't move Tidsmaskinen", error.localizedDescription)
                return
            }
        }
        AppSettings.defaults.set(hadLoginItem, forKey: SettingsKey.relocationRestoreLoginItem)
        do {
            try relaunch(target)
        } catch {
            // The bundle has moved; the pending flag restores the login item
            // on the next launch from the new location.
            showFailure("Tidsmaskinen was moved to ~/Applications",
                        "Quit Tidsmaskinen and open it again from ~/Applications. (\(error.localizedDescription))")
            releaseUpdater()
        }
    }

    private static func releaseUpdater() {
        startUpdater?()
        startUpdater = nil
    }

    /// Mirrors Sparkle's check: no admin needed only when the bundle and its
    /// parent are writable and the bundle is owned by the current user.
    static func updatesNeedAdmin(_ bundleURL: URL) -> Bool {
        let fm = FileManager.default
        let parent = bundleURL.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: bundleURL.path), fm.isWritableFile(atPath: parent) else { return true }
        let owner = (try? fm.attributesOfItem(atPath: bundleURL.path)[.ownerAccountID] as? NSNumber)?.uint32Value
        return owner != getuid()
    }

    /// Shell command that moves the bundle into `~/Applications` and gives it
    /// to the current user. Runs as root, so it also fixes a root-owned copy.
    ///
    /// `rm -rf` clears any stale copy at the target: `mv` can't replace a
    /// non-empty directory, and two bundles with this bundle ID would leave
    /// Launch Services picking between them arbitrarily. It runs as part of the
    /// privileged command so nothing is deleted unless the user approved the
    /// move. A failed chown afterwards is not fatal: the next launch lands in
    /// the chown-only branch and repairs it.
    static func moveCommand(from bundleURL: URL, to target: URL) -> String {
        // Sparkle checks the parent folder too, so a root-owned ~/Applications
        // would keep every update prompting even after the bundle itself is
        // ours. Not recursive: it must not touch other apps living there.
        let parent = shellQuoted(target.deletingLastPathComponent().path)
        // chown alone leaves the mode bits, so a 0555 folder stays unwritable
        // and Sparkle would keep asking. u+rwx is what its check actually reads.
        let own = "chown \(getuid()):\(getgid()) \(parent); chmod u+rwx \(parent); "
            + "chown -R \(getuid()):\(getgid()) \(shellQuoted(target.path))"
        if bundleURL.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() { return own }
        return "rm -rf \(shellQuoted(target.path)) && mv -f \(shellQuoted(bundleURL.path)) "
            + "\(shellQuoted(target.path)) && { \(own) || true; }"
    }

    /// AppleScript that runs `command` as root. The long timeout covers an
    /// Admin By Request approval that waits on a remote administrator.
    static func adminScriptSource(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
            with timeout of 3600 seconds
                do shell script "\(escaped)" with administrator privileges
            end timeout
            """
    }

    private static func move(_ bundleURL: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: userApplications, withIntermediateDirectories: true)
        try runAsAdmin(moveCommand(from: bundleURL, to: target))
    }

    /// Whether the bundle actually arrived at `target` and left its old home.
    /// An unresolved outcome is re-checked for a few seconds: a privileged
    /// command can outlive the Apple event that reported a timeout.
    private static func moveLanded(from bundleURL: URL, to target: URL, waitingUpTo seconds: Int = 0) -> Bool {
        guard bundleURL.resolvingSymlinksInPath() != target.resolvingSymlinksInPath() else { return true }
        let fm = FileManager.default
        for attempt in 0...max(0, seconds) {
            if fm.fileExists(atPath: target.path) && !fm.fileExists(atPath: bundleURL.path) { return true }
            if attempt < seconds { Thread.sleep(forTimeInterval: 1) }
        }
        return false
    }

    /// A reported timeout says nothing about whether the command ran, so give
    /// it a moment to settle. A refusal is final and needs no wait.
    private static func waitForMoveSeconds(after error: Error) -> Int {
        if case RelocationError.cancelled = error { return 0 }
        return 5
    }

    /// Why the destination must not be replaced, or nil when it is free to
    /// take. Anything unrecognised is left alone rather than deleted.
    static func destinationRefusal(at target: URL,
                                   ourVersion: String,
                                   ourBundleID: String?) -> (title: String, detail: String)? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard let bundle = Bundle(url: target), bundle.bundleIdentifier == ourBundleID else {
            return ("Something else is already there",
                    """
                    \(target.path) exists and isn't a copy of Tidsmaskinen, so it won't be touched.

                    Move or rename it, then try again.
                    """)
        }
        let theirs = bundleVersion(of: bundle)
        if isNewer(theirs, than: ourVersion) {
            return ("A newer Tidsmaskinen is already installed",
                    """
                    Version \(theirs) is in your home Applications folder, and this copy is older.

                    Quit this one and open that copy instead. You can then drag this older copy to \
                    the Trash.
                    """)
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ourBundleID ?? "")
        if running.contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath() == target.resolvingSymlinksInPath()
        }) {
            return ("That copy is already running",
                    """
                    Tidsmaskinen is already running from your home Applications folder.

                    Use that copy, and drag this one to the Trash.
                    """)
        }
        return nil
    }

    static func bundleVersion(of bundle: Bundle) -> String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Numeric comparison, so 0.3.15 sorts above 0.3.9 rather than below it.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private static func runAsAdmin(_ command: String) throws {
        guard let script = NSAppleScript(source: adminScriptSource(for: command)) else {
            throw RelocationError.failed("Couldn't build the move command.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        switch errorInfo[NSAppleScript.errorNumber] as? Int {
        case -128, -1712: // user cancelled / Apple event timed out: nothing moved
            throw RelocationError.cancelled
        default:
            throw RelocationError.failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)")
        }
    }

    /// Same dance as Sparkle's Autoupdate: wait for this process to exit, then
    /// open the moved bundle so only one instance touches the database.
    ///
    /// `open` runs only once this process is gone, so its exit status can't be
    /// observed from here. Checking that the bundle arrived is what we can do
    /// before the point of no return; a launch that fails after that surfaces
    /// as the app simply not reappearing, and the user reopens it by hand.
    private static func relaunch(_ target: URL) throws {
        guard FileManager.default.isExecutableFile(
            atPath: target.appendingPathComponent("Contents/MacOS/Tidsmaskinen").path
        ) else {
            throw RelocationError.failed("Tidsmaskinen isn't where it should be after the move.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(shellQuoted(target.path))"]
        try waiter.run()
        NSApp.terminate(nil)
    }

    /// Rewrites the coding-agent hooks that point into the bundle's old home.
    /// They record an absolute `tm-hook` path, so after a move they invoke a
    /// binary that no longer exists and session capture stops without a word.
    /// Scoped to the launch after a relocation: a Sparkle update replaces the
    /// bundle in place, so nothing else moves the path out from under them.
    private static func repairCodingAgentHooks() -> Bool {
        CodingAgentProvider.allCases.allSatisfy { provider in
            switch HookInstaller.currentState(provider: provider) {
            case .installed, .notInstalled: return true
            case .stale: return (try? HookInstaller.install(provider: provider)) != nil
            // A config we couldn't read may hold hooks pointing at the old
            // path, so this is unrepaired, not absent.
            case .error: return false
            }
        }
    }

    /// Finishes the work a completed move left for the next launch. The flag
    /// is cleared only once every repair has actually succeeded, so a failure
    /// is retried instead of being lost.
    private static func finishPendingRelocation() {
        let defaults = AppSettings.defaults
        guard defaults.object(forKey: SettingsKey.relocationRestoreLoginItem) != nil else { return }
        var repaired = repairCodingAgentHooks()
        if defaults.bool(forKey: SettingsKey.relocationRestoreLoginItem) {
            repaired = ((try? LoginItemManager.reregister()) != nil) && repaired
        }
        guard repaired else { return }
        defaults.removeObject(forKey: SettingsKey.relocationRestoreLoginItem)
    }

    private static func showFailure(_ title: String, _ detail: String) {
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = title
        failure.informativeText = detail
        // Accessory apps aren't frontmost, so an alert would open behind
        // whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        failure.runModal()
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum RelocationError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Cancelled."
            case .failed(let message): return message
            }
        }
    }
}
