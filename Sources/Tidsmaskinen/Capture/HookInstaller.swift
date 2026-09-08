import Foundation

/// Installs lifecycle hooks without replacing unrelated settings or hook handlers.
enum HookInstaller {
    static func settingsPath(for provider: CodingAgentProvider) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if provider == .claude { return home.appendingPathComponent(".claude/settings.json") }
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("hooks.json")
    }

    static let eventNames = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"]

    static func events(for provider: CodingAgentProvider) -> [String] {
        eventNames + (provider == .codex ? ["Interrupt"] : [])
    }

    static func tmHookPath() -> String? {
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tm-hook"),
           FileManager.default.isExecutableFile(atPath: exe.path) {
            return exe.path
        }
        return nil
    }

    enum InstallState: Equatable {
        case notInstalled
        case installed(path: String)
        case stale(installedPath: String, expectedPath: String)
        case error(String)
    }

    static func currentState(provider: CodingAgentProvider = .claude,
                             fileURL: URL? = nil, executablePath: String? = nil) -> InstallState {
        guard let expected = executablePath ?? tmHookPath() else { return .error("tm-hook binary not found in bundle") }
        do {
            let settings = try readSettings(at: fileURL ?? settingsPath(for: provider))
            let hooks = settings["hooks"] as? [String: Any] ?? [:]
            let commands = events(for: provider).map { event in
                (hooks[event] as? [[String: Any]] ?? []).flatMap { entry -> [String] in
                    let handlers = entry["hooks"] as? [[String: Any]] ?? [entry]
                    return handlers.compactMap { $0["command"] as? String }.filter { isOurCommand($0, provider: provider) }
                }
            }
            guard commands.contains(where: { !$0.isEmpty }) else { return .notInstalled }
            if zip(events(for: provider), commands).allSatisfy({ event, found in
                found.count == 1 && words(found[0]) == arguments(path: expected, event: event, provider: provider)
            }) {
                return .installed(path: expected)
            }
            let installed = commands.flatMap { $0 }.first.flatMap { words($0).first } ?? expected
            return .stale(installedPath: installed, expectedPath: expected)
        } catch { return .error(error.localizedDescription) }
    }

    @discardableResult
    static func install(provider: CodingAgentProvider = .claude,
                        fileURL: URL? = nil, executablePath: String? = nil) throws -> InstallState {
        guard let expected = executablePath ?? tmHookPath() else { throw invalid("tm-hook binary not found") }
        let url = fileURL ?? settingsPath(for: provider)
        var settings = try readSettings(at: url)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events(for: provider) {
            var entries = hooks[event] as? [[String: Any]] ?? []
            stripOurHooks(from: &entries, provider: provider)
            let command = arguments(path: expected, event: event, provider: provider).map(shellQuote).joined(separator: " ")
            entries.append(["matcher": "", "hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        try writeSettings(settings, at: url)
        return .installed(path: expected)
    }

    @discardableResult
    static func uninstall(provider: CodingAgentProvider = .claude, fileURL: URL? = nil) throws -> InstallState {
        let url = fileURL ?? settingsPath(for: provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return .notInstalled }
        var settings = try readSettings(at: url)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events(for: provider) {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            stripOurHooks(from: &entries, provider: provider)
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeSettings(settings, at: url)
        return .notInstalled
    }

    private static func arguments(path: String, event: String, provider: CodingAgentProvider) -> [String] {
        [path] + (provider == .codex ? ["--provider", "codex"] : []) + [event]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Tokenize only to recognize our simple command; never evaluate shell code.
    private static func words(_ command: String) -> [String] {
        var result: [String] = [], word = ""
        var quote: Character?, escaped = false
        for c in command {
            if escaped { word.append(c); escaped = false; continue }
            if c == "\\", quote != "'" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
            } else if c == "'" || c == "\"" { quote = c
            } else if c.isWhitespace {
                if !word.isEmpty { result.append(word); word = "" }
            } else { word.append(c) }
        }
        guard quote == nil, !escaped else { return [] }
        if !word.isEmpty { result.append(word) }
        return result
    }

    private static func isOurCommand(_ command: String, provider: CodingAgentProvider) -> Bool {
        let parts = words(command)
        guard let first = parts.first, (first as NSString).lastPathComponent == "tm-hook" else { return false }
        if provider == .codex {
            return parts.count == 4 && parts[1] == "--provider" && parts[2] == "codex" && events(for: provider).contains(parts[3])
        }
        return parts.count == 2 && eventNames.contains(parts[1])
    }

    private static func stripOurHooks(from entries: inout [[String: Any]], provider: CodingAgentProvider) {
        entries = entries.compactMap { entry in
            var entry = entry
            if var inner = entry["hooks"] as? [[String: Any]] {
                inner.removeAll { ($0["command"] as? String).map { isOurCommand($0, provider: provider) } ?? false }
                guard !inner.isEmpty else { return nil }
                entry["hooks"] = inner
            } else if let cmd = entry["command"] as? String, isOurCommand(cmd, provider: provider) { return nil }
            return entry
        }
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "HookInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw invalid("Expected a JSON object in \(url.path). File left unchanged.")
        }
        if let value = settings["hooks"] {
            guard let hooks = value as? [String: Any], hooks.values.allSatisfy({ $0 is [[String: Any]] }) else {
                throw invalid("Invalid hooks configuration in \(url.path). File left unchanged.")
            }
            for entries in hooks.values {
                for entry in entries as! [[String: Any]] {
                    if let inner = entry["hooks"], !(inner is [[String: Any]]) {
                        throw invalid("Invalid hook handlers in \(url.path). File left unchanged.")
                    }
                }
            }
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any], at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("tm-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
