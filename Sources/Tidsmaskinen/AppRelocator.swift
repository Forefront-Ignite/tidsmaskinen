import AppKit
import Foundation
import Security

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

    /// Posted once relocation is settled and the app is staying put.
    /// `AppState` holds its updater back until then, so an update can't
    /// install into a bundle that is about to be replaced — an Admin By
    /// Request approval can leave that pending for minutes. A broadcast
    /// rather than a callback: SwiftUI builds `AppState` more than once during
    /// startup, and a single slot would leave the retained one stopped.
    static let didSettle = Notification.Name("AppRelocatorDidSettle")

    /// False once relocation is settled, so an `AppState` built afterwards
    /// starts its updater immediately instead of waiting for a notification
    /// that has already been posted.
    private(set) static var isHoldingUpdater = false

    /// Whether a freshly built updater should wait. Reading it marks the hold,
    /// so the notification is posted even if `run()` never gets that far.
    static var shouldHoldUpdater: Bool {
        guard isMovePending else { return false }
        isHoldingUpdater = true
        return true
    }

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
            && isInSystemApplications(bundleURL)
            && updatesNeedAdmin(bundleURL)
            && !AppSettings.relocationPromptSuppressed
    }

    static let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Whether the bundle sits inside the system `/Applications`. Only that
    /// case earns an elevated delete: the folder is `root:admin`, so nothing
    /// running as the user can swap a component of the path between this check
    /// and the command. An install anywhere else can be moved by its owner
    /// without any rights, and elevating there would hand root a path the user
    /// controls.
    static func isInSystemApplications(_ bundleURL: URL) -> Bool {
        bundleURL.resolvingSymlinksInPath().path
            .hasPrefix(systemApplications.resolvingSymlinksInPath().path + "/")
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
                AppSettings.relocationPromptSuppressed = true
            }
            return releaseUpdater()
        }

        // The login item is tied to the bundle's inode and path. Drop it now
        // and re-register from the new location after relaunch.
        let hadLoginItem = LoginItemManager.isEnabled
        if hadLoginItem { try? LoginItemManager.setEnabled(false) }

        // Copy first, unprivileged. Writing into the user's own home needs no
        // rights at all, which keeps every root operation off paths the user
        // (or anything running as them) can swap.
        do {
            try placeCopy(of: bundleURL, at: target)
        } catch {
            if hadLoginItem { try? LoginItemManager.setEnabled(true) }
            showFailure("Couldn't copy Tidsmaskinen", error.localizedDescription)
            return releaseUpdater()
        }

        // Record the repair *before* elevating. If the process dies between a
        // successful delete and writing this, the next launch would otherwise
        // never repoint the login item or the coding-agent hooks. It is a
        // no-op when nothing ends up changing.
        AppSettings.defaults.set(hadLoginItem, forKey: SettingsKey.relocationRestoreLoginItem)

        // All root has left to do is drop the old copy, and only because
        // removing an entry from /Applications needs write access there.
        // Re-checked here because the guard above ran before the prompt.
        do {
            guard isInSystemApplications(bundleURL) else {
                throw RelocationError.failed("Tidsmaskinen isn't in /Applications any more.")
            }
            try runAsAdmin(removeCommand(for: bundleURL))
        } catch {
            // `rm -rf` is not transactional: it can destroy part of the old
            // bundle and still report failure. Undo our copy only when the old
            // one is provably still whole — deleting both would leave no
            // working app at all.
            if oldCopyIsIntact(bundleURL) {
                try? FileManager.default.removeItem(at: target)
                AppSettings.defaults.removeObject(forKey: SettingsKey.relocationRestoreLoginItem)
                if hadLoginItem { try? LoginItemManager.setEnabled(true) }
                defer { releaseUpdater() }
                if case RelocationError.cancelled = error { return }
                showFailure("Couldn't remove the old copy", error.localizedDescription)
                return
            }
            // The old copy is gone or half-deleted. Keep the new one and hand
            // over to it; the repair flag stays set so the next launch
            // repoints the login item and hooks.
            showFailure("Tidsmaskinen is now in ~/Applications",
                        """
                        The copy in /Applications couldn't be removed cleanly, so Tidsmaskinen will \
                        carry on from ~/Applications.

                        Drag anything left behind in /Applications to the Trash when convenient.
                        """)
        }

        do {
            try relaunch(target)
        } catch {
            // The copy is in place and the old one is gone; the pending flag
            // repoints the login item and hooks on the next launch.
            showFailure("Tidsmaskinen is now in ~/Applications",
                        "Open it from ~/Applications to carry on. (\(error.localizedDescription))")
            releaseUpdater()
        }
    }

    private static func releaseUpdater() {
        guard isHoldingUpdater else { return }
        isHoldingUpdater = false
        NotificationCenter.default.post(name: didSettle, object: nil)
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

    /// The only step that needs rights: removing the entry from
    /// `/Applications`. That folder is `root:admin`, so nothing running as the
    /// user can swap this path between the check and the command, which is
    /// what made an elevated move across `~/Applications` unsafe. `rm -rf`
    /// deletes symlinks rather than following them, so contents can't redirect
    /// it either.
    static func removeCommand(for bundleURL: URL) -> String {
        "rm -rf \(shellQuoted(bundleURL.path))"
    }

    /// Whether the bundle at `bundleURL` is still a complete, correctly signed
    /// copy. A half-deleted bundle fails the signature check, which is what
    /// makes it safe to tell "nothing was removed" apart from "removal got
    /// part way".
    static func oldCopyIsIntact(_ bundleURL: URL, verify: (URL) -> Bool = signedLikeUs) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL.path) && verify(bundleURL)
    }

    /// Copies the running bundle to `target` as the user. Replaces an existing
    /// copy only after `destinationRefusal` has cleared it, and verifies the
    /// result still carries our signature before anything is handed over to it.
    private static func placeCopy(of bundleURL: URL, at target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: bundleURL, to: target)
        guard signedLikeUs(target) else {
            try? fm.removeItem(at: target)
            throw RelocationError.failed("The copy in ~/Applications didn't come out intact.")
        }
    }

    /// Why the destination must not be replaced, or nil when it is free to
    /// take. Anything unrecognised is left alone rather than deleted.
    static func destinationRefusal(at target: URL,
                                   ourVersion: String,
                                   ourBundleID: String?,
                                   isSignedLikeUs: (URL) -> Bool = signedLikeUs) -> (title: String, detail: String)? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard let bundle = Bundle(url: target), bundle.bundleIdentifier == ourBundleID else {
            return ("Something else is already there",
                    """
                    \(target.path) exists and isn't a copy of Tidsmaskinen, so it won't be touched.

                    Move or rename it, then try again.
                    """)
        }
        // Any bundle can claim our identifier, and root is about to delete this
        // path, so the claim has to be backed by our own signing identity.
        guard isSignedLikeUs(target) else {
            return ("That copy can't be verified",
                    """
                    \(target.path) says it is Tidsmaskinen but isn't signed like this copy, so it \
                    won't be touched.

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

    /// Whether the bundle at `url` satisfies this app's own designated
    /// requirement, i.e. is the same app from the same signing identity.
    nonisolated static func signedLikeUs(_ url: URL) -> Bool {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &candidate) == errSecSuccess,
              let candidate
        else { return false }
        return SecStaticCodeCheckValidity(candidate, [], requirement) == errSecSuccess
    }

    static func bundleVersion(of bundle: Bundle) -> String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Numeric comparison, so 0.3.15 sorts above 0.3.9 rather than below it.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
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
