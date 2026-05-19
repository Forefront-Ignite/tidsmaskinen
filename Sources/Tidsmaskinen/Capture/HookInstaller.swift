import Foundation

/// Reads `~/.claude/settings.json` and idempotently adds/removes our tm-hook
/// entries for SessionStart / SessionEnd / UserPromptSubmit. Preserves any
/// hooks the user added by hand.
enum HookInstaller {
    static let claudeSettingsPath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json", isDirectory: false)
    }()

    static let eventNames = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"]

    /// Path to the bundled tm-hook binary inside our .app bundle.
    /// Falls back to the SwiftPM debug build when running outside a bundle (development).
    static func tmHookPath() -> String? {
        let bundle = Bundle.main
        if let exe = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("tm-hook"),
           FileManager.default.isExecutableFile(atPath: exe.path) {
            return exe.path
        }
        // Dev fallback: running via `swift run` — look beside the main binary.
        if let main = bundle.executablePath {
            let sibling = (main as NSString).deletingLastPathComponent + "/tm-hook"
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return nil
    }

    enum InstallState: Equatable {
        case notInstalled
        case installed(path: String)
        case stale(installedPath: String, expectedPath: String)
        case error(String)
    }

    static func currentState() -> InstallState {
        guard let expected = tmHookPath() else { return .error("tm-hook binary not found in bundle") }
        guard let settings = readSettings() else {
            return .notInstalled
        }
        guard let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
        var found: String?
        for event in eventNames {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            for entry in entries {
                if let cmd = tmHookCommand(in: entry) {
                    found = cmd
                    break
                }
            }
            if found != nil { break }
        }
        guard let cmd = found else { return .notInstalled }
        let path = String(cmd.split(separator: " ").first ?? Substring(cmd))
        if path == expected {
            return .installed(path: expected)
        }
        return .stale(installedPath: path, expectedPath: expected)
    }

    @discardableResult
    static func install() throws -> InstallState {
        guard let expected = tmHookPath() else {
            throw NSError(domain: "HookInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "tm-hook binary not found"])
        }
        var settings = readSettings() ?? [:]
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for event in eventNames {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            stripTmHook(from: &entries)
            // Claude Code's schema: each entry is { matcher, hooks: [{ type, command }] }.
            // Lifecycle events (SessionStart/End, UserPromptSubmit, Stop) have no
            // tool-name matcher, so use an empty string.
            entries.append([
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": "\(expected) \(event)"]
                ]
            ])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
        return .installed(path: expected)
    }

    @discardableResult
    static func uninstall() throws -> InstallState {
        guard var settings = readSettings(),
              var hooks = settings["hooks"] as? [String: Any] else {
            return .notInstalled
        }
        for event in eventNames {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            stripTmHook(from: &entries)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
        return .notInstalled
    }

    /// Extracts our tm-hook command from an entry in either the correct
    /// wrapped shape `{ matcher, hooks: [{ command }] }` or the legacy flat
    /// shape `{ command }` that earlier builds wrote.
    private static func tmHookCommand(in entry: [String: Any]) -> String? {
        if let inner = entry["hooks"] as? [[String: Any]] {
            for h in inner {
                if let cmd = h["command"] as? String, cmd.contains("tm-hook") { return cmd }
            }
            return nil
        }
        if let cmd = entry["command"] as? String, cmd.contains("tm-hook") { return cmd }
        return nil
    }

    /// Removes any tm-hook references from `entries`, preserving any sibling
    /// hooks the user added inside the same matcher group. Handles both shapes.
    private static func stripTmHook(from entries: inout [[String: Any]]) {
        var i = 0
        while i < entries.count {
            var entry = entries[i]
            if var inner = entry["hooks"] as? [[String: Any]] {
                inner.removeAll { ($0["command"] as? String)?.contains("tm-hook") == true }
                if inner.isEmpty {
                    entries.remove(at: i)
                    continue
                }
                entry["hooks"] = inner
                entries[i] = entry
            } else if (entry["command"] as? String)?.contains("tm-hook") == true {
                entries.remove(at: i)
                continue
            }
            i += 1
        }
    }

    // MARK: - Settings file I/O

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeSettings(_ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: claudeSettingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeSettingsPath, options: .atomic)
    }
}
