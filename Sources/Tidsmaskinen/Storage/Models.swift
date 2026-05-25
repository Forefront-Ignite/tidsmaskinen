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

    enum Kind: String, Codable, CaseIterable, Identifiable, Hashable {
        case gitRemoteHost
        case gitRepoSlug
        case urlHost
        case urlPath
        case windowTitle
        case appBundleID

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gitRemoteHost: return "Git remote host"
            case .gitRepoSlug:   return "Git repo (owner/name)"
            case .urlHost:       return "Browser URL host"
            case .urlPath:       return "Browser URL path"
            case .windowTitle:   return "Window title contains"
            case .appBundleID:   return "App bundle ID"
            }
        }

        var placeholder: String {
            switch self {
            case .gitRemoteHost: return "github.com"
            case .gitRepoSlug:   return "forefront/*"
            case .urlHost:       return "*.acme.com"
            case .urlPath:       return "github.com/forefront/*"
            case .windowTitle:   return "Acme staging"
            case .appBundleID:   return "com.acme.app"
            }
        }

        var supportsGlob: Bool {
            switch self {
            case .windowTitle: return false
            default: return true
            }
        }
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

    /// Stretch each event's effective time range to absorb adjacent mic
    /// activity, so meeting under/overshoot inherits the meeting's
    /// attribution and rolls into Timeline + weekly report without manual
    /// intervention. A mic session that overlaps the booked event extends the
    /// event back to its start (joined early) and forward to its end (ran
    /// long), capped at the previous/next event boundary so back-to-back
    /// meetings don't bleed into each other.
    ///
    /// Returns in-memory copies — does not mutate persisted rows.
    static func withMicOverrun(events: [CalendarEvent],
                                micSessions: [MicSession],
                                now: Date = Date()) -> [CalendarEvent] {
        guard !events.isEmpty, !micSessions.isEmpty else { return events }
        // A mic session must overlap the event by at least this many seconds
        // to count as real participation. Without this, an unrelated mic
        // session that ends a few seconds into the next meeting (e.g. a
        // 9:49-10:00 Slack huddle ending 30s after a 10:00 meeting starts)
        // gets absorbed whole into that meeting.
        let minOverlapSeconds: TimeInterval = 120
        var extended = events.sorted { $0.startAt < $1.startAt }
        for i in extended.indices {
            let originalStart = extended[i].startAt
            let originalEnd = extended[i].endAt
            // Cap against the (possibly already extended) neighbor on each
            // side so an overrun can't push past the next meeting.
            let prevEnd = i > 0 ? extended[i - 1].endAt : Date.distantPast
            let nextStart = i + 1 < extended.count ? extended[i + 1].startAt : Date.distantFuture
            var newStart = originalStart
            var newEnd = originalEnd
            for mic in micSessions {
                let micEnd = mic.endedAt ?? now
                let overlapStart = max(mic.startedAt, originalStart)
                let overlapEnd = min(micEnd, originalEnd)
                guard overlapEnd.timeIntervalSince(overlapStart) >= minOverlapSeconds else { continue }
                if mic.startedAt < originalStart {
                    newStart = min(newStart, max(mic.startedAt, prevEnd))
                }
                if micEnd > originalEnd {
                    newEnd = max(newEnd, min(micEnd, nextStart))
                }
            }
            extended[i].startAt = newStart
            extended[i].endAt = newEnd
        }
        return extended
    }
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

    static let databaseTableName = "activity_samples"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let capturedAt = Column(CodingKeys.capturedAt)
        static let appBundleID = Column(CodingKeys.appBundleID)
        static let appName = Column(CodingKeys.appName)
        static let isIdle = Column(CodingKeys.isIdle)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct HiddenSignal: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, Hashable {
        case appBundleID
        case urlHost
    }

    var id: String
    var kind: Kind
    var value: String
    var hiddenAt: Date

    static let databaseTableName = "hidden_signals"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let kind = Column(CodingKeys.kind)
        static let value = Column(CodingKeys.value)
        static let hiddenAt = Column(CodingKeys.hiddenAt)
    }
}

struct MicSession: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var voipAppsCSV: String?
    var participant: String?
    var customerID: String?
    var projectID: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "mic_sessions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let startedAt = Column(CodingKeys.startedAt)
        static let endedAt = Column(CodingKeys.endedAt)
        static let voipAppsCSV = Column(CodingKeys.voipAppsCSV)
        static let participant = Column(CodingKeys.participant)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    var voipApps: [String] {
        voipAppsCSV?.split(separator: ",").map(String.init) ?? []
    }

    var durationSeconds: Double? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}
