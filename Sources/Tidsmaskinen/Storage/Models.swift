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
        case windowTitle
        case appBundleID
        case slackChannel

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gitRemoteHost: return "Git remote host"
            case .gitRepoSlug:   return "Git repo (owner/name)"
            case .urlHost:       return "Browser URL host"
            case .urlPath:       return "Browser URL path"
            case .windowTitle:   return "Window title contains"
            case .appBundleID:   return "App bundle ID"
            case .slackChannel:  return "Slack channel"
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
            case .slackChannel:  return "nfc-internal"
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

    /// How much a mic session must overlap a booking before it may *stretch*
    /// it. Without this, a session that ends a few seconds into the next meeting
    /// (a 9:49-10:00 huddle running 30s past a 10:00 booking) would drag that
    /// meeting's start backwards. Ownership itself has no such floor — see
    /// `meetingMicSessionIDs`.
    static let meetingMicOverlapSeconds: TimeInterval = 120

    /// The mic sessions that count as a meeting's *own* audio, keyed by event id.
    ///
    /// A booking only owns sessions on the platform it is held on: a
    /// `teamsForBusiness` event is attended in Teams, so a Slack huddle that
    /// starts inside the booking is a *different call* — the meeting ended
    /// early and you took a huddle — and must not be swallowed by the block.
    /// Meetings with no typed provider (in-person, dial-in, a Meet link buried
    /// in the body) own every overlapping session, preserving prior behaviour.
    ///
    /// Any overlap at all is enough. `meetingMicOverlapSeconds` deliberately
    /// does *not* apply here: it guards stretching, and using it for ownership
    /// too would leave a sub-2-minute fragment of a meeting's own audio
    /// unsubtracted, surfacing it as a phantom ad-hoc call and a Review item.
    ///
    /// Ignored meetings own nothing — they contribute no time themselves, so
    /// letting one absorb a call would delete that call's hours outright.
    ///
    /// A meeting can own several sessions: mic access drops and resumes mid-call
    /// often enough that one booking maps to two or three Teams sessions.
    ///
    /// Safe to call with either raw or `withMicOverrun`-extended events — the
    /// answer is the same, and consumers pass whichever they have. `MicMonitor`
    /// keeps a single open session (`endSession()` always precedes
    /// `beginSession()`), so sessions never overlap; an event's extension is by
    /// construction covered by a session that event already owns, and a serial
    /// session is disjoint from it. Any *other* session therefore overlaps the
    /// extended bounds exactly as much as it overlaps the booked ones. If
    /// `MicMonitor` ever tracks concurrent sessions this stops holding, and
    /// callers must switch to the raw booked events.
    static func meetingMicSessionIDs(events: [CalendarEvent],
                                     micSessions: [MicSession],
                                     now: Date = Date(),
                                     minimumOverlapSeconds: TimeInterval = 0) -> [String: Set<String>] {
        var owned: [String: Set<String>] = [:]
        for event in events where !event.isIgnored {
            for mic in micSessions where event.micPlatformMatches(mic) {
                let micEnd = mic.endedAt ?? now
                let overlapStart = max(mic.startedAt, event.startAt)
                let overlapEnd = min(micEnd, event.endAt)
                let overlap = overlapEnd.timeIntervalSince(overlapStart)
                // Strictly positive, so sessions that merely abut a boundary
                // (they always do — MicMonitor closes one as it opens the next)
                // aren't claimed.
                guard overlap > 0, overlap >= minimumOverlapSeconds else { continue }
                owned[event.id, default: []].insert(mic.id)
            }
        }
        return owned
    }

    /// True when `session` could be this meeting's own audio. Only Teams and
    /// Skype bookings can be typed from Graph today; every other provider
    /// matches anything.
    ///
    /// The test is *positive evidence of a rival platform*, not absence of
    /// Teams. A Teams meeting joined from the browser records `com.google.chrome`
    /// (or Safari/Brave/Arc/Edge), and an unrecognised or empty app list says
    /// nothing either way — treating any of those as a mismatch would strip a
    /// real meeting of its own audio, bill the same hour twice, and drop the
    /// join-early/run-late tails. Only an app that is definitely some *other*
    /// platform rules the session out.
    func micPlatformMatches(_ session: MicSession) -> Bool {
        switch onlineMeetingProvider {
        case "teamsForBusiness", "skypeForBusiness":
            let apps = session.voipApps
            if apps.contains(where: { $0.hasPrefix("com.microsoft.teams") || $0.contains("skype") }) {
                return true
            }
            return !apps.contains(where: Self.isRivalVoipApp)
        default:
            return true
        }
    }

    /// Bundle IDs that unambiguously identify a non-Teams calling platform.
    /// Browsers are excluded on purpose — they host Teams as readily as anything
    /// else. Note a session's app list is a growing union (`MicMonitor` merges
    /// overlapping recorders), so a session that ever held Teams stays Teams.
    static func isRivalVoipApp(_ bundleID: String) -> Bool {
        bundleID.contains("slack") || bundleID.contains("zoom") || bundleID.contains("webex")
            || bundleID.contains("discord") || bundleID.contains("facetime")
            || bundleID.hasPrefix("cisco-systems.spark")
    }

    /// Stretch each event's effective time range to absorb adjacent mic
    /// activity, so meeting under/overshoot inherits the meeting's
    /// attribution and rolls into Timeline + weekly report without manual
    /// intervention. A mic session the meeting *owns* extends the event back to
    /// its start (joined early) and forward to its end (ran long), capped at the
    /// previous/next event boundary so back-to-back meetings don't bleed into
    /// each other. Sessions the meeting doesn't own — a huddle on another
    /// platform taken during the booking — can't stretch it.
    ///
    /// Returns in-memory copies — does not mutate persisted rows.
    static func withMicOverrun(events: [CalendarEvent],
                                micSessions: [MicSession],
                                now: Date = Date()) -> [CalendarEvent] {
        guard !events.isEmpty, !micSessions.isEmpty else { return events }
        // Stretching needs real participation, not just any overlap.
        let owned = meetingMicSessionIDs(events: events, micSessions: micSessions, now: now,
                                         minimumOverlapSeconds: meetingMicOverlapSeconds)
        var extended = events.sorted { $0.startAt < $1.startAt }
        for i in extended.indices {
            guard let mine = owned[extended[i].id] else { continue }
            let originalStart = extended[i].startAt
            let originalEnd = extended[i].endAt
            // Cap against the (possibly already extended) neighbor on each
            // side so an overrun can't push past the next meeting.
            let prevEnd = i > 0 ? extended[i - 1].endAt : Date.distantPast
            let nextStart = i + 1 < extended.count ? extended[i + 1].startAt : Date.distantFuture
            var newStart = originalStart
            var newEnd = originalEnd
            for mic in micSessions where mine.contains(mic.id) {
                let micEnd = mic.endedAt ?? now
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
        case urlPath
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
    /// Slack channel inferred from the frontmost Slack window titles captured
    /// during the session (e.g. `nfc-internal`). Lets a `slackChannel` rule
    /// auto-attribute huddles in the Calls tab. `nil` for non-Slack sessions
    /// or huddles in DMs.
    var slackChannel: String?
    var customerID: String?
    var projectID: String?
    /// User chose "Ignore" for this session — hide it from Review and never
    /// count it in the weekly report (mirrors `CalendarEvent.isIgnored`).
    var isIgnored: Bool = false
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "mic_sessions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let startedAt = Column(CodingKeys.startedAt)
        static let endedAt = Column(CodingKeys.endedAt)
        static let voipAppsCSV = Column(CodingKeys.voipAppsCSV)
        static let participant = Column(CodingKeys.participant)
        static let slackChannel = Column(CodingKeys.slackChannel)
        static let customerID = Column(CodingKeys.customerID)
        static let projectID = Column(CodingKeys.projectID)
        static let isIgnored = Column(CodingKeys.isIgnored)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    var voipApps: [String] {
        voipAppsCSV?.split(separator: ",").map(String.init) ?? []
    }

    var durationSeconds: Double? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// Extracts the Slack channel name from a single Slack window title.
    /// Recognizes the two shapes Slack uses:
    ///   `nfc-internal (Channel) - Forefront Ignite - … - Slack`
    ///   `Huddle: nfc-internal – Forefront Ignite – Slack 🎤`
    /// Returns `nil` for DM windows/huddles (`@person`, `(DM)`) and anything
    /// that isn't a recognizable channel title.
    static func parseSlackChannel(fromTitle title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: " (Channel)") {
            var name = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Private channels carry a literal "#" in Slack's window titles
            // (public ones are bare) — strip it so storage, rules, and labels
            // all see one format.
            if name.hasPrefix("#") { name = String(name.dropFirst()) }
            return name.isEmpty ? nil : name
        }
        if t.hasPrefix("Huddle:") {
            var rest = String(t.dropFirst("Huddle:".count))
            // Cut at the first " <dash> " separator (Slack uses an en dash).
            if let sep = rest.range(of: #"\s[–—-]\s"#, options: .regularExpression) {
                rest = String(rest[..<sep.lowerBound])
            }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty || rest.hasPrefix("@") { return nil } // DM huddle
            if rest.hasPrefix("#") { rest = String(rest.dropFirst()) }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// Slack's built-in views, which use the same bare title shape as a huddle
    /// window but name no conversation.
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

    /// Extracts the most-frequent participant name from Teams window titles,
    /// which look like `<Name> | <Org> | <email> | Microsoft Teams`. Picks the
    /// first segment per title that isn't "Chat", "Microsoft Teams", an email,
    /// or empty. Returns nil when no usable title was seen.
    static func parseTeamsParticipant(fromTitles titles: [String]) -> String? {
        var counts: [String: Int] = [:]
        for title in titles {
            let parts = title.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            for p in parts {
                let lower = p.lowercased()
                if lower == "chat" || lower == "microsoft teams" { continue }
                if p.contains("@") { continue }
                if p.isEmpty { continue }
                counts[p, default: 0] += 1
                break
            }
        }
        return counts.max { $0.value < $1.value }.map { $0.key }
    }
}
