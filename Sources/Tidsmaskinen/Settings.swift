import Foundation

enum SettingsKey {
    static let sampleIntervalSeconds = "sampleIntervalSeconds"
    static let idleThresholdSeconds = "idleThresholdSeconds"
    static let trackIdleDuringMeetings = "trackIdleDuringMeetings"
    static let meetingRSVPFilter = "meetingRSVPFilter"
    static let verifyMeetingAttendance = "verifyMeetingAttendance"
    static let parallelAttribution = "parallelAttribution"
    static let graphClientID = "graphClientID"
    static let graphTenantID = "graphTenantID"
    static let calendarAutoSyncMinutes = "calendarAutoSyncMinutes"
    static let graphPreset = "graphPreset"
    static let claudeIdleThresholdMinutes = "claudeIdleThresholdMinutes"
    static let aiModel = "aiModel"
    static let aiAuthMode = "aiAuthMode"
}

enum AIAuthMode: String, CaseIterable, Identifiable {
    case claudeCodeCLI
    case apiKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCodeCLI: return "Claude Code CLI (use your subscription)"
        case .apiKey:        return "Anthropic API key (separate billing)"
        }
    }
}

enum GraphPreset: String, CaseIterable, Identifiable {
    case forefront
    case microsoftPublic
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forefront:       return "Forefront"
        case .microsoftPublic: return "Microsoft (public client)"
        case .custom:          return "Custom"
        }
    }

    var clientID: String? {
        switch self {
        case .forefront:       return "03331bbf-77ec-4642-852b-32474b7304e5"
        case .microsoftPublic: return "14d82eec-204b-4c2f-b7e8-296a70dab67e"
        case .custom:          return nil
        }
    }

    var tenantID: String? {
        switch self {
        case .forefront:       return "forefront.se"
        case .microsoftPublic: return "common"
        case .custom:          return nil
        }
    }

    static func match(clientID: String, tenantID: String) -> GraphPreset {
        for preset in GraphPreset.allCases where preset != .custom {
            if preset.clientID == clientID, preset.tenantID == tenantID {
                return preset
            }
        }
        return .custom
    }
}

enum MeetingRSVPFilter: String, CaseIterable, Identifiable {
    case acceptedOnly
    case acceptedAndTentative
    case all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .acceptedOnly: return "Accepted only"
        case .acceptedAndTentative: return "Accepted + Tentative"
        case .all: return "All invites (incl. declined)"
        }
    }
}

/// Read-only access to user settings for non-View call sites.
/// Views should use `@AppStorage` directly so they reactively rebuild.
enum AppSettings {
    static let defaults = UserDefaults.standard

    static var sampleIntervalSeconds: Int {
        let v = defaults.integer(forKey: SettingsKey.sampleIntervalSeconds)
        return v <= 0 ? 15 : v
    }

    static var idleThresholdSeconds: Int {
        let v = defaults.integer(forKey: SettingsKey.idleThresholdSeconds)
        return v <= 0 ? 300 : v
    }

    static var trackIdleDuringMeetings: Bool {
        if defaults.object(forKey: SettingsKey.trackIdleDuringMeetings) == nil { return true }
        return defaults.bool(forKey: SettingsKey.trackIdleDuringMeetings)
    }

    static var meetingRSVPFilter: MeetingRSVPFilter {
        guard let raw = defaults.string(forKey: SettingsKey.meetingRSVPFilter),
              let value = MeetingRSVPFilter(rawValue: raw) else {
            return .acceptedAndTentative
        }
        return value
    }

    static var verifyMeetingAttendance: Bool {
        defaults.bool(forKey: SettingsKey.verifyMeetingAttendance)
    }

    static var parallelAttribution: Bool {
        if defaults.object(forKey: SettingsKey.parallelAttribution) == nil { return true }
        return defaults.bool(forKey: SettingsKey.parallelAttribution)
    }

    // MARK: Graph

    static let defaultGraphPreset: GraphPreset = .forefront
    static var defaultGraphClientID: String { defaultGraphPreset.clientID ?? "" }
    static var defaultGraphTenantID: String { defaultGraphPreset.tenantID ?? "" }

    static var graphClientID: String {
        let v = defaults.string(forKey: SettingsKey.graphClientID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultGraphClientID : v
    }

    static var graphTenantID: String {
        let v = defaults.string(forKey: SettingsKey.graphTenantID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultGraphTenantID : v
    }

    /// Calendar auto-sync interval, minutes. 0 = disabled.
    static var calendarAutoSyncMinutes: Int {
        if defaults.object(forKey: SettingsKey.calendarAutoSyncMinutes) == nil { return 5 }
        return defaults.integer(forKey: SettingsKey.calendarAutoSyncMinutes)
    }

    /// A Claude Code session counts as idle after this many minutes without a hook event.
    /// Gaps between events larger than this are clamped — only the first N minutes are counted as active.
    static var claudeIdleThresholdMinutes: Int {
        if defaults.object(forKey: SettingsKey.claudeIdleThresholdMinutes) == nil { return 5 }
        let v = defaults.integer(forKey: SettingsKey.claudeIdleThresholdMinutes)
        return v <= 0 ? 5 : v
    }

    static let defaultAIModel = "claude-sonnet-4-6"
    static var aiModel: String {
        let v = defaults.string(forKey: SettingsKey.aiModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultAIModel : v
    }

    static var aiAuthMode: AIAuthMode {
        if let raw = defaults.string(forKey: SettingsKey.aiAuthMode),
           let mode = AIAuthMode(rawValue: raw) {
            return mode
        }
        // Auto-detect: prefer CLI if claude binary is reachable, else require API key.
        return ClaudeCLIDetector.findClaudeBinary() != nil ? .claudeCodeCLI : .apiKey
    }
}

enum ClaudeCLIDetector {
    static let candidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        NSHomeDirectory() + "/.local/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude"
    ]

    /// Returns the absolute path to a `claude` binary if one can be located, else nil.
    static func findClaudeBinary() -> String? {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: `which claude` via login shell so user's PATH is respected.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "which claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, fm.isExecutableFile(atPath: out) {
                return out
            }
        } catch {
            // ignore
        }
        return nil
    }
}
