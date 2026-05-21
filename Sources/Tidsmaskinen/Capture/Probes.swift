import Foundation
import AppKit
// @preconcurrency: the ApplicationServices C-bridged constants like
// `kAXTrustedCheckOptionPrompt` are declared as global `var` in the SDK
// even though they're effectively immutable after process start. Swift 6
// flags any read as unsafe; treat those as warnings until Apple annotates
// them.
@preconcurrency import ApplicationServices

enum Probes {
    static let codeEditorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.cursor.Cursor",
        "com.todesktop.230313mzl4w4u92"  // Cursor (early build)
    ]

    static let chromiumBrowserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "company.thebrowser.Browser"  // Arc — note: Arc has its own AppleScript model and is NOT supported here yet
    ]

    static let chromeBundleID = "com.google.Chrome"

    /// Last AppleScript error from `chromeActiveTabURL`. Useful for diagnostics.
    /// Single-writer (ActivityMonitor's main-thread timer); the debug Diagnostics
    /// view reads it on main too. nonisolated(unsafe) avoids dragging actor
    /// isolation through the whole module.
    nonisolated(unsafe) static var lastChromeError: String?

    /// Captured once at first access so we don't repeatedly reach into the
    /// global var `kAXTrustedCheckOptionPrompt` from concurrent contexts.
    /// String is Sendable; the underlying CFString is process-lifetime.
    private static let axTrustedCheckOptionPrompt: String =
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

    static func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        let opts: NSDictionary = [axTrustedCheckOptionPrompt: promptIfNeeded]
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func isChromeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == chromeBundleID }
    }

    enum AutomationPermissionStatus: Equatable {
        case granted
        case denied(OSStatus)
        case targetNotRunning
        case unknown(OSStatus)

        var displayString: String {
            switch self {
            case .granted: return "granted"
            case .denied(let s): return "denied (OSStatus \(s))"
            case .targetNotRunning: return "target app not running"
            case .unknown(let s): return "unknown (OSStatus \(s))"
            }
        }
    }

    /// Asks macOS to issue (or recall) the Automation prompt for sending AppleEvents to the
    /// target bundle. Pass `prompt: true` to force the prompt to appear if the user hasn't
    /// answered yet. Requires the host app to be signed with
    /// `com.apple.security.automation.apple-events` and have `NSAppleEventsUsageDescription`
    /// in its Info.plist — without those the call returns silently denied.
    static func requestAutomationPermission(forBundle bundleID: String, prompt: Bool) -> AutomationPermissionStatus {
        guard let cString = bundleID.cString(using: .utf8) else { return .unknown(0) }
        var target = AEAddressDesc()
        let createErr: OSErr = AECreateDesc(
            DescType(typeApplicationBundleID),
            cString,
            cString.count - 1,        // exclude trailing NUL
            &target
        )
        guard createErr == noErr else { return .unknown(OSStatus(createErr)) }
        defer { AEDisposeDesc(&target) }

        let status: OSStatus = withUnsafePointer(to: &target) { ptr in
            AEDeterminePermissionToAutomateTarget(
                ptr,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                prompt
            )
        }

        switch status {
        case noErr:
            return .granted
        case OSStatus(-600):              // procNotFound
            return .targetNotRunning
        case OSStatus(-1743), OSStatus(-1744):
            // -1743 errAEEventNotPermitted, -1744 errAETargetAddressNotPermitted
            return .denied(status)
        default:
            return .unknown(status)
        }
    }

    static func windowTitle(pid: pid_t) -> String? {
        guard isAccessibilityTrusted(promptIfNeeded: false) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        guard err == .success, let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(unsafeDowncast(window, to: AXUIElement.self),
                                      kAXTitleAttribute as CFString,
                                      &title)
        return title as? String
    }

    static func windowDocumentPath(pid: pid_t) -> String? {
        guard isAccessibilityTrusted(promptIfNeeded: false) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var doc: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(window, to: AXUIElement.self),
                                            kAXDocumentAttribute as CFString,
                                            &doc) == .success,
              let raw = doc as? String else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url.path }
        if raw.hasPrefix("/") { return raw }
        return nil
    }

    private static let chromeScriptSource = """
    tell application "Google Chrome"
        try
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        on error errMsg number errNum
            return "ERR:" & errNum & ":" & errMsg
        end try
    end tell
    """

    // NSAppleScript isn't Sendable but is only ever used from the main thread
    // (ActivityMonitor.captureNow runs on the main runloop). nonisolated(unsafe)
    // pins this acknowledgement at the storage site rather than per call.
    nonisolated(unsafe) private static let chromeScript: NSAppleScript? = NSAppleScript(source: chromeScriptSource)

    /// Returns the URL of the active tab if Chrome is frontmost.
    /// First successful call triggers an Automation permission prompt for Google Chrome.
    static func chromeActiveTabURL() -> String? {
        guard isChromeRunning() else {
            lastChromeError = "Chrome is not running"
            return nil
        }
        var error: NSDictionary?
        guard let result = chromeScript?.executeAndReturnError(&error) else {
            lastChromeError = "AppleScript engine returned nil"
            return nil
        }
        if let error {
            lastChromeError = "Script error: \(error)"
            return nil
        }
        let value = result.stringValue ?? ""
        if value.hasPrefix("ERR:") {
            lastChromeError = String(value.dropFirst(4))
            return nil
        }
        if value.isEmpty {
            lastChromeError = "Empty (no front window?)"
            return nil
        }
        lastChromeError = nil
        return value
    }

    static func host(for url: String) -> String? {
        URL(string: url)?.host
    }

    static func findGitRoot(near path: String) -> String? {
        let fm = FileManager.default
        var dir = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir), !isDir.boolValue {
            dir = (dir as NSString).deletingLastPathComponent
        }
        while dir.count > 1 {
            let gitPath = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    static func gitOriginURL(repoRoot: String) -> String? {
        let configPath = (repoRoot as NSString).appendingPathComponent(".git/config")
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    struct Diagnostics {
        var accessibilityTrusted: Bool
        var frontmostBundleID: String?
        var frontmostName: String?
        var frontmostPID: pid_t?
        var capturedWindowTitle: String?
        var capturedDocumentPath: String?
        var capturedGitRoot: String?
        var capturedGitOrigin: String?
        var chromeRunning: Bool
        var capturedChromeURL: String?
        var chromeError: String?
        var notes: [String] = []
    }

    static func runDiagnostics() -> Diagnostics {
        var d = Diagnostics(
            accessibilityTrusted: isAccessibilityTrusted(promptIfNeeded: false),
            chromeRunning: isChromeRunning()
        )
        let frontmost = NSWorkspace.shared.frontmostApplication
        d.frontmostBundleID = frontmost?.bundleIdentifier
        d.frontmostName = frontmost?.localizedName
        d.frontmostPID = frontmost?.processIdentifier

        if let pid = d.frontmostPID {
            d.capturedWindowTitle = windowTitle(pid: pid)
            d.capturedDocumentPath = windowDocumentPath(pid: pid)
            if let docPath = d.capturedDocumentPath,
               let root = findGitRoot(near: docPath) {
                d.capturedGitRoot = root
                d.capturedGitOrigin = gitOriginURL(repoRoot: root)
            }
        }

        if d.chromeRunning {
            d.capturedChromeURL = chromeActiveTabURL()
            d.chromeError = lastChromeError
        } else {
            d.chromeError = "Chrome is not running"
        }

        // Generate human-readable notes.
        if !d.accessibilityTrusted {
            d.notes.append("Accessibility permission is OFF — window titles and VS Code repo detection will be empty.")
        }
        if let bid = d.frontmostBundleID {
            if codeEditorBundleIDs.contains(bid), d.capturedDocumentPath == nil {
                d.notes.append("Frontmost is a code editor but no AXDocument is exposed — usually means no file is focused (sidebar / welcome / extensions tab). Click into a code file to test.")
            }
            if bid == chromeBundleID, d.capturedChromeURL == nil {
                d.notes.append("Frontmost is Chrome but no URL came back. If this is the first time, accept the Automation prompt for Google Chrome. Otherwise see the error below.")
            }
            if bid != chromeBundleID, chromiumBrowserBundleIDs.contains(bid), bid != "com.brave.Browser" {
                d.notes.append("\(d.frontmostName ?? bid) is a Chromium-family browser but only Google Chrome's AppleScript dictionary is wired. Switch to Chrome (or open an issue to add this browser).")
            }
        }
        return d
    }
}
