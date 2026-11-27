import Foundation
import GRDB

/// Marker for the upstream system this row was imported from.
/// Locally-created rows have `nil`. `commandCenter` rows are read-only in the
/// UI; `commandCenterArchived` rows are hidden from pickers but kept for
/// historical reports.
enum ExternalSource: String, Codable, Hashable {
    case commandCenter = "command-center"
    case commandCenterArchived = "command-center-archived"
}

/// Stable palette used when a row has no stored color. Command Center's
/// `Client` API doesn't expose a client color, so every CC customer would
/// otherwise collapse to the fallback blue in the UI.
enum ColorPalette {
    static let hexes = [
        "#3B82F6", // blue
        "#10B981", // emerald
        "#F59E0B", // amber
        "#EF4444", // red
        "#8B5CF6", // violet
        "#EC4899", // pink
        "#14B8A6", // teal
        "#F97316", // orange
        "#22C55E", // green
        "#6366F1", // indigo
    ]

    /// Deterministic pick from `hexes` derived from `key`. Stable across
    /// process restarts (does not use `String.hashValue`, which is randomized
    /// per launch).
    static func deterministic(for key: String) -> String {
        var sum: UInt64 = 0
        for scalar in key.unicodeScalars {
            sum = sum &+ UInt64(scalar.value)
            sum = sum &* 1_315_423_911
        }
        return hexes[Int(sum % UInt64(hexes.count))]
    }
}

struct Customer: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var color: String?
    var createdAt: Date
    var externalSource: String?
    var externalID: String?
    var externalSyncedAt: Date?

    static let databaseTableName = "customers"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let color = Column(CodingKeys.color)
        static let createdAt = Column(CodingKeys.createdAt)
        static let externalSource = Column(CodingKeys.externalSource)
        static let externalID = Column(CodingKeys.externalID)
        static let externalSyncedAt = Column(CodingKeys.externalSyncedAt)
    }

    var external: ExternalSource? { externalSource.flatMap(ExternalSource.init(rawValue:)) }
    var isExternal: Bool { external == .commandCenter }
    var isArchived: Bool { external == .commandCenterArchived }

    /// Color to render. Falls back to a deterministic palette pick when no
    /// color is stored (Command Center's client API doesn't surface one).
    var displayColor: String { color ?? ColorPalette.deterministic(for: id) }
}

struct Project: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String
    var customerID: String
    var name: String
    var color: String?
    var createdAt: Date
    var externalSource: String?
    var externalID: String?
    var externalSyncedAt: Date?
    var engagementType: String?     // "tm" | "fixed_price" | "retainer" | "prospect" | "internal" (CC only)
    var externalColor: String?      // CC-provided color; user-edited `color` wins on display

    static let databaseTableName = "projects"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let customerID = Column(CodingKeys.customerID)
        static let name = Column(CodingKeys.name)
        static let color = Column(CodingKeys.color)
        static let externalSource = Column(CodingKeys.externalSource)
        static let externalID = Column(CodingKeys.externalID)
        static let externalSyncedAt = Column(CodingKeys.externalSyncedAt)
        static let engagementType = Column(CodingKeys.engagementType)
        static let externalColor = Column(CodingKeys.externalColor)
    }

    var external: ExternalSource? { externalSource.flatMap(ExternalSource.init(rawValue:)) }
    var isExternal: Bool { external == .commandCenter }
    var isArchived: Bool { external == .commandCenterArchived }

    /// Color to render. Local edits take precedence; falls back to the
    /// CC-provided color, then to a deterministic palette pick so a project
    /// with no stored color still varies between rows.
    var displayColor: String { color ?? externalColor ?? ColorPalette.deterministic(for: id) }
}

struct Rule: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String
    var customerID: String
    var projectID: String?
    var kind: Kind
    var pattern: String
    var priority: Int
    var createdAt: Date
    /// Optional validity window. When both are nil the rule is permanent.
    /// A bounded rule only matches activity whose timestamp falls in
    /// `[validFrom, validTo)` — used for "attribute this week / today only".
    var validFrom: Date? = nil
    var validTo: Date? = nil

    /// True when this rule attributes activity at the given instant.
    func isValid(at date: Date) -> Bool {
        if let from = validFrom, date < from { return false }
        if let to = validTo, date >= to { return false }
        return true
    }

    /// A rule with any bound set is temporary (expires / is windowed).
    var isTemporary: Bool { validFrom != nil || validTo != nil }

    enum Kind: String, Codable, CaseIterable, Identifiable, Hashable {
        case gitRemoteHost
        case gitRepoSlug
        case urlHost
        case urlPath
        case appBundleID

        /// Kinds earlier versions wrote. Their rows stay in the database but
        /// are never loaded: `windowTitle` (no one used it), `slackChannel`
        /// (Slack was replaced by Cells) and `participant` (call detection
        /// was removed). Every rule query filters on `activeRawValues`.
        static let retiredRawValues = ["windowTitle", "slackChannel", "participant"]
        static var activeRawValues: [String] { allCases.map(\.rawValue) }

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gitRemoteHost: return "Git remote host"
            case .gitRepoSlug:   return "Git repo (owner/name)"
            case .urlHost:       return "Browser URL host"
            case .urlPath:       return "Browser URL path"
            case .appBundleID:   return "App bundle ID"
            }
        }

        var placeholder: String {
            switch self {
            case .gitRemoteHost: return "github.com"
            case .gitRepoSlug:   return "forefront/*"
            case .urlHost:       return "*.acme.com"
            case .urlPath:       return "github.com/forefront/*"
            case .appBundleID:   return "com.acme.app"
            }
        }

        /// Every kind matches with `*` wildcards.
        var supportsGlob: Bool { true }
    }

    static let databaseTableName = "rules"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
        static let kind = Column(CodingKeys.kind)
        static let pattern = Column(CodingKeys.pattern)
        static let priority = Column(CodingKeys.priority)
    }
}

/// Providers sharing the session activity pipeline. Existing table/type names stay
/// stable so historical Claude sessions and their attribution remain intact.
enum CodingAgentProvider: String, Codable, DatabaseValueConvertible, CaseIterable {
    case claude, codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }

    func storedSessionID(_ rawID: String) -> String {
        self == .claude ? rawID : "codex:\(rawID)"
    }
}

struct ClaudeSession: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String              // session_id from the hook payload
    var cwd: String?
    var transcriptPath: String?
    var gitRepoPath: String?
    var gitRemoteURL: String?
    var startedAt: Date
    var endedAt: Date?
    var lastActivityAt: Date?
    var activeSeconds: Double   // accumulated active time, idle gaps clamped
    var promptCount: Int
    var customerID: String?     // optional manual override
    var projectID: String?
    var createdAt: Date
    var updatedAt: Date

    var provider: CodingAgentProvider = .claude

    static let databaseTableName = "claude_sessions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let startedAt = Column(CodingKeys.startedAt)
        static let endedAt = Column(CodingKeys.endedAt)
        static let lastActivityAt = Column(CodingKeys.lastActivityAt)
        static let activeSeconds = Column(CodingKeys.activeSeconds)
        static let cwd = Column(CodingKeys.cwd)
        static let gitRepoPath = Column(CodingKeys.gitRepoPath)
        static let gitRemoteURL = Column(CodingKeys.gitRemoteURL)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
    }

    /// Wall-clock duration between SessionStart and SessionEnd. Informational; not used for billing.
    var lifetimeSeconds: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    /// Active duration counting current session if still active, with idle gap clamped at threshold.
    func amortizedActiveSeconds(now: Date = Date(), idleThresholdSeconds: TimeInterval) -> Double {
        guard endedAt == nil, let last = lastActivityAt else { return activeSeconds }
        let trailing = min(max(0, now.timeIntervalSince(last)), idleThresholdSeconds)
        return activeSeconds + trailing
    }

    func isActive(now: Date = Date(), idleThresholdSeconds: TimeInterval) -> Bool {
        guard endedAt == nil, let last = lastActivityAt else { return false }
        return now.timeIntervalSince(last) < idleThresholdSeconds
    }
}

struct CalendarEvent: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String                  // Microsoft Graph event id
    var iCalUID: String?
    var subject: String
    var bodyPreview: String?
    var startAt: Date
    var endAt: Date
    var isAllDay: Bool
    var organizerEmail: String?
    var organizerName: String?
    var rsvpStatus: String          // accepted | tentativelyAccepted | declined | notResponded | none | organizer
    var isOnlineMeeting: Bool
    var onlineMeetingProvider: String?
    var attendeeDomainsCSV: String?  // distinct non-self domains, comma-separated
    var location: String?
    var verifiedAttended: Bool
    var customerID: String?         // optional manual override
    var projectID: String?
    /// Microsoft Graph event type: "singleInstance" | "occurrence" | "exception" | "seriesMaster".
    var eventType: String?
    /// Set on occurrence/exception rows, points at the series master's id.
    var seriesMasterID: String?
    /// Per-event ignore flag — excludes the event from Timeline and weekly report.
    var isIgnored: Bool
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "calendar_events"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let startAt = Column(CodingKeys.startAt)
        static let endAt = Column(CodingKeys.endAt)
        static let rsvpStatus = Column(CodingKeys.rsvpStatus)
        static let attendeeDomainsCSV = Column(CodingKeys.attendeeDomainsCSV)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
        static let eventType = Column(CodingKeys.eventType)
        static let seriesMasterID = Column(CodingKeys.seriesMasterID)
        static let isIgnored = Column(CodingKeys.isIgnored)
    }

    var attendeeDomains: [String] {
        attendeeDomainsCSV?.split(separator: ",").map(String.init) ?? []
    }

    var durationMinutes: Int {
        max(0, Int(endAt.timeIntervalSince(startAt) / 60))
    }

    /// Seconds of this event inside `interval`. Every surface that sums
    /// meeting time for a period (Review, Discover, the report) clips this way.
    func seconds(within interval: DateInterval) -> Double {
        max(0, min(endAt, interval.end).timeIntervalSince(max(startAt, interval.start)))
    }
}

/// A week the user has filed: what it summed to and when, so a later sync
/// that changes the number is flagged instead of silently rewriting a figure
/// already reported.
struct ReportedWeek: Codable, FetchableRecord, PersistableRecord, Equatable {
    var weekStart: Date
    var reportedAt: Date
    var totalHours: Double

    static let databaseTableName = "reported_weeks"
}

/// Per-series attribution. Keyed by the Graph series master id; one row per
/// recurring series. `customerID` nil + `isIgnored` true means "ignore this
/// series"; `customerID` set means "attribute every occurrence to this customer
/// unless the specific occurrence has its own override".
struct MeetingSeriesAttribution: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String { seriesMasterID }
    var seriesMasterID: String
    var customerID: String?
    var projectID: String?
    var isIgnored: Bool
    var updatedAt: Date

    static let databaseTableName = "meeting_series_attributions"

    enum Columns {
        static let seriesMasterID = Column(CodingKeys.seriesMasterID)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
        static let isIgnored = Column(CodingKeys.isIgnored)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

struct ActivitySample: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var capturedAt: Date
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var chromeURL: String?
    var chromeHost: String?
    var gitRepoPath: String?
    var gitRemoteURL: String?
    var isIdle: Bool
    var customerID: String?      // manual override from timeline view
    var projectID: String?
    /// The Claude Code or Codex session in front when this was captured
    /// (`claude_sessions.id`). Nil for other apps and when it can't be read.
    var agentSessionID: String? = nil
    /// The Cells chat open in the Cells window (its `AXDocument` names it).
    var cellsChatID: String? = nil

    static let databaseTableName = "activity_samples"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let capturedAt = Column(CodingKeys.capturedAt)
        static let appBundleID = Column(CodingKeys.appBundleID)
        static let appName = Column(CodingKeys.appName)
        static let isIdle = Column(CodingKeys.isIdle)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
        static let agentSessionID = Column(CodingKeys.agentSessionID)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct HiddenSignal: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, Hashable {
        case gitRepoSlug
        case appBundleID
        case urlHost
        case urlPath

        var systemImage: String {
            switch self {
            case .gitRepoSlug: return "chevron.left.forwardslash.chevron.right"
            case .appBundleID: return "app"
            case .urlHost: return "globe"
            case .urlPath: return "link"
            }
        }
    }

    var id: String
    var kind: Kind
    var value: String
    var hiddenAt: Date

    static let databaseTableName = "hidden_signals"

    func matches(kind: Kind, value: String) -> Bool {
        self.kind == kind && (kind == .gitRepoSlug
            ? self.value.lowercased() == value.lowercased()
            : self.value == value)
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let kind = Column(CodingKeys.kind)
        static let value = Column(CodingKeys.value)
        static let hiddenAt = Column(CodingKeys.hiddenAt)
    }
}

/// Call detection is gone; its `mic_sessions` rows stay in the database with
/// no readers. These Slack huddle-title parsers remain only because the
/// historical migrations v13, v15, v16 and v21 call them.
enum MicSession {
    /// Slack sidebar views whose names look like a person or channel in a title.
    private static let slackViewNames: Set<String> = [
        "threads", "new message", "drafts & sent", "activity", "later", "canvases",
        "files", "templates", "automations", "slack connect", "huddles", "home",
        "signal", "search", "saved items", "mentions & reactions", "all dms",
        "people", "apps", "more"
    ]

    /// The conversation a Slack *huddle window* names, and whether it's a
    /// channel. Slack has used two title formats:
    ///
    ///   `Huddle: nfc-internal – Forefront Ignite – Slack 🎤`  (until Aug 2026)
    ///   `Huddle: @Victor Vadelius – Forefront Ignite – Slack 🎤`
    ///   `Victor Vadelius - Forefront Ignite - Slack`          (current)
    ///
    /// The current format dropped the `Huddle:` prefix and the `@`/`#` marker,
    /// so the huddle window is identified by what it *lacks*: main-window
    /// titles always carry a `(DM)`/`(Channel)` suffix, are tagged `[Main]`
    /// while a second window exists, and may carry an `N new items` counter —
    /// a huddle title has none of those. Channel vs person is then decided by
    /// shape: Slack forces channel names to lowercase with no spaces, so
    /// anything with a capital or a space is a person.
    /// ponytail: shape heuristic — an all-lowercase display name reads as a
    /// channel. Revisit if Slack ever re-marks huddle titles.
    static func parseSlackHuddleTitle(fromTitle title: String) -> (name: String, isChannel: Bool)? {
        // Slack mixes en/em dashes with hyphens across the two formats.
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        var name: String
        var explicitPerson = false

        if t.hasPrefix("Huddle:") {
            let rest = String(t.dropFirst("Huddle:".count))
            name = (rest.components(separatedBy: " - ").first ?? rest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("@") {
                name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
                explicitPerson = true
            }
        } else {
            guard !t.contains("[Main]"), !t.contains("(DM)"), !t.contains("(Channel)"),
                  t.range(of: #" - \d+ new items? - "#, options: .regularExpression) == nil
            else { return nil }
            // `<name> - <workspace> - Slack` (plus optional trailing emoji).
            let parts = t.components(separatedBy: " - ")
            guard parts.count >= 3, parts[parts.count - 1].hasPrefix("Slack") else { return nil }
            name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if slackViewNames.contains(name.lowercased()) { return nil }
        }

        if name.hasPrefix("#") { name = String(name.dropFirst()) }
        else if explicitPerson { return name.isEmpty ? nil : (name, false) }
        else if name.isEmpty { return nil }
        else {
            // Channel names are lowercase and space-free; display names aren't.
            let isChannel = name.range(of: #"^[a-z0-9][a-z0-9._-]*$"#,
                                       options: .regularExpression) != nil
            return (name, isChannel)
        }
        return name.isEmpty ? nil : (name, true)
    }

    /// The channel a huddle belonged to, taken **only** from huddle-window
    /// titles. Plain channel-navigation windows (`<channel> (Channel) …`) are
    /// deliberately ignored: a channel you merely clicked into during a call is
    /// not the call's channel. Returns nil for DM huddles and for any session
    /// with no channel-huddle title at all — those simply aren't channel
    /// huddles, and guessing from navigation produces false attributions.
    /// Ties break on frequency.
    static func bestSlackChannel(fromTitles titles: [String]) -> String? {
        bestSlackHuddleName(fromTitles: titles, channels: true)
    }

    /// Most-frequent 1:1 huddle counterpart across the session's Slack titles.
    static func bestSlackHuddlePerson(fromTitles titles: [String]) -> String? {
        bestSlackHuddleName(fromTitles: titles, channels: false)
    }

    private static func bestSlackHuddleName(fromTitles titles: [String], channels: Bool) -> String? {
        var counts: [String: Int] = [:]
        for raw in titles {
            guard let parsed = parseSlackHuddleTitle(fromTitle: raw),
                  parsed.isChannel == channels else { continue }
            counts[parsed.name, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
