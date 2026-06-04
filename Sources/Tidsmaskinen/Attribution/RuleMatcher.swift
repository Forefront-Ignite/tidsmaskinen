import Foundation

struct AttributionResult: Equatable {
    let customer: Customer?
    let project: Project?
    let matchingRule: Rule?

    static let unattributed = AttributionResult(customer: nil, project: nil, matchingRule: nil)
}

/// Attribution result for a single calendar event. Carries enough state for
/// the UI to show *why* the event is attributed (per-occurrence override vs
/// series rule) and to distinguish "ignored" from "unattributed".
enum EventAttribution: Equatable {
    enum Source: Equatable { case event, series }

    case attributed(customer: Customer, project: Project?, source: Source)
    case ignored(source: Source)
    case unattributed

    var customer: Customer? {
        if case .attributed(let c, _, _) = self { return c }
        return nil
    }

    var project: Project? {
        if case .attributed(_, let p, _) = self { return p }
        return nil
    }

    var isIgnored: Bool {
        if case .ignored = self { return true }
        return false
    }

    /// Project-the-event-onto-WeeklyReport view: just the attributed customer
    /// and project, with no source distinction. Ignored events return
    /// `.unattributed` here because they shouldn't contribute hours to any
    /// bucket — callers should skip ignored events before calling this.
    var asAttributionResult: AttributionResult {
        if case .attributed(let c, let p, _) = self {
            return AttributionResult(customer: c, project: p, matchingRule: nil)
        }
        return .unattributed
    }
}

struct RuleMatcher {
    let customersByID: [String: Customer]
    let projectsByID: [String: Project]
    let rulesByKind: [Rule.Kind: [Rule]]
    let seriesAttributionsByID: [String: MeetingSeriesAttribution]

    static func load(from db: AppDatabase) throws -> RuleMatcher {
        let customers = try db.allCustomers()
        let projects = try db.allProjects()
        let rules = try db.allRules()
        let series = try db.allMeetingSeriesAttributions()
        return make(customers: customers, projects: projects, rules: rules, series: series)
    }

    static func make(customers: [Customer],
                     projects: [Project],
                     rules: [Rule],
                     series: [MeetingSeriesAttribution] = []) -> RuleMatcher {
        let byID = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        let projByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let byKind = Dictionary(grouping: rules, by: { $0.kind })
            .mapValues { $0.sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.pattern.count > rhs.pattern.count
            } }
        let seriesByID = Dictionary(uniqueKeysWithValues: series.map { ($0.seriesMasterID, $0) })
        return RuleMatcher(
            customersByID: byID,
            projectsByID: projByID,
            rulesByKind: byKind,
            seriesAttributionsByID: seriesByID
        )
    }

    func attribute(_ sample: ActivitySample) -> AttributionResult {
        // Manual override beats rules.
        if let customerID = sample.customerID, let customer = customersByID[customerID] {
            let project = sample.projectID.flatMap { projectsByID[$0] }
            return AttributionResult(customer: customer, project: project, matchingRule: nil)
        }
        // Time-bounded ("this week"/"today") rules only apply to activity within
        // their window — match against this sample's own capture time.
        let at = sample.capturedAt
        // Most-specific signals first.
        if let url = sample.gitRemoteURL {
            if let slug = Self.gitSlug(fromRemote: url),
               let r = match(kind: .gitRepoSlug, against: slug, at: at) {
                return result(for: r)
            }
            if let host = Self.gitHost(fromRemote: url),
               let r = match(kind: .gitRemoteHost, against: host, at: at) {
                return result(for: r)
            }
        }
        if let url = sample.chromeURL,
           let normalized = Self.normalizedURL(url),
           let r = match(kind: .urlPath, against: normalized, at: at) {
            return result(for: r)
        }
        if let host = sample.chromeHost,
           let r = match(kind: .urlHost, against: host, at: at) {
            return result(for: r)
        }
        // Slack channel rules: parse the channel out of the Slack window title
        // and match it before the generic window-title rules, so e.g.
        // `nfc-internal → NCF` attributes foreground Slack time too (not just
        // huddles in the Calls tab).
        if let bundle = sample.appBundleID?.lowercased(), bundle.contains("slack"),
           let title = sample.windowTitle,
           let channel = MicSession.parseSlackChannel(fromTitle: title),
           let r = match(kind: .slackChannel, against: channel, at: at) {
            return result(for: r)
        }
        if let title = sample.windowTitle,
           let r = match(kind: .windowTitle, against: title, at: at) {
            return result(for: r)
        }
        if let bundle = sample.appBundleID,
           let r = match(kind: .appBundleID, against: bundle, at: at) {
            return result(for: r)
        }
        return .unattributed
    }

    private func result(for rule: Rule) -> AttributionResult {
        let project = rule.projectID.flatMap { projectsByID[$0] }
        return AttributionResult(
            customer: customersByID[rule.customerID],
            project: project,
            matchingRule: rule
        )
    }

    /// Attribute a Claude Code session. Manual override (session.customerID/projectID)
    /// wins; otherwise match by gitRemoteURL → slug → host fallback.
    func attribute(session: ClaudeSession) -> AttributionResult {
        if let customerID = session.customerID, let customer = customersByID[customerID] {
            let project = session.projectID.flatMap { projectsByID[$0] }
            return AttributionResult(customer: customer, project: project, matchingRule: nil)
        }
        let at = session.lastActivityAt ?? session.startedAt
        if let url = session.gitRemoteURL {
            if let slug = Self.gitSlug(fromRemote: url),
               let r = match(kind: .gitRepoSlug, against: slug, at: at) {
                return result(for: r)
            }
            if let host = Self.gitHost(fromRemote: url),
               let r = match(kind: .gitRemoteHost, against: host, at: at) {
                return result(for: r)
            }
        }
        return .unattributed
    }

    /// Attribute a mic session (Calls tab). Manual override
    /// (session.customerID/projectID) wins; otherwise match the inferred Slack
    /// channel against `slackChannel` rules. The result's `matchingRule` is
    /// non-nil exactly when the attribution came from a rule rather than a
    /// manual save, which the UI uses to label auto-matched rows.
    func attribute(micSession s: MicSession) -> AttributionResult {
        if let cid = s.customerID, let customer = customersByID[cid] {
            let project = s.projectID.flatMap { projectsByID[$0] }
            return AttributionResult(customer: customer, project: project, matchingRule: nil)
        }
        if let channel = s.slackChannel,
           let r = match(kind: .slackChannel, against: channel, at: s.startedAt) {
            return result(for: r)
        }
        return .unattributed
    }

    /// Attribute a calendar event. Priority:
    ///   1. event.isIgnored                             → .ignored(.event)
    ///   2. event.customerID set                        → .attributed(_, _, .event)
    ///   3. series ignored (if seriesMasterID != nil)   → .ignored(.series)
    ///   4. series has customerID                       → .attributed(_, _, .series)
    ///   5. otherwise                                   → .unattributed
    func attribute(event: CalendarEvent) -> EventAttribution {
        if event.isIgnored {
            return .ignored(source: .event)
        }
        if let customerID = event.customerID, let customer = customersByID[customerID] {
            let project = event.projectID.flatMap { projectsByID[$0] }
            return .attributed(customer: customer, project: project, source: .event)
        }
        if let seriesID = event.seriesMasterID,
           let series = seriesAttributionsByID[seriesID] {
            if series.isIgnored {
                return .ignored(source: .series)
            }
            if let cid = series.customerID, let customer = customersByID[cid] {
                let project = series.projectID.flatMap { projectsByID[$0] }
                return .attributed(customer: customer, project: project, source: .series)
            }
        }
        return .unattributed
    }

    /// Helper for the Discover view: attribute a raw signal value of a given kind without
    /// constructing a fake ActivitySample.
    /// `at` defaults to now so time-bounded rules are evaluated for the current
    /// instant when a call site has no specific timestamp (e.g. the Discover /
    /// Review "is this attributed?" check reflects whether a window rule is
    /// active right now).
    func attribute(kind: Rule.Kind, value: String, at: Date? = nil) -> AttributionResult {
        let when = at ?? Date()
        if let r = match(kind: kind, against: value, at: when) {
            return result(for: r)
        }
        // Slug rules also imply remote-host fallback.
        if kind == .gitRepoSlug, let host = value.split(separator: "/").first.map(String.init),
           let r = match(kind: .gitRemoteHost, against: host, at: when) {
            return result(for: r)
        }
        // URL path rules fall back to host rules: `github.com/forefront/foo` → host `github.com`.
        if kind == .urlPath, let host = value.split(separator: "/").first.map(String.init),
           let r = match(kind: .urlHost, against: host, at: when) {
            return result(for: r)
        }
        return .unattributed
    }

    private func match(kind: Rule.Kind, against value: String, at date: Date) -> Rule? {
        guard let candidates = rulesByKind[kind] else { return nil }
        let valid = candidates.filter {
            $0.isValid(at: date) && Self.matches(kind: kind, pattern: $0.pattern, value: value)
        }
        // Conflict resolution: the most *precise* rule wins. A rule bounded to a
        // narrow window (today) outranks a wider one (this week), which outranks
        // a permanent "always" rule — because a bounded rule is a deliberate
        // override for that period. Ties fall back to priority, then the longer
        // (more specific) pattern.
        return valid.min { a, b in
            let wa = Self.ruleWindow(a), wb = Self.ruleWindow(b)
            if wa != wb { return wa < wb }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.pattern.count > b.pattern.count
        }
    }

    /// A rule's time-window size, used to rank specificity. Smaller = more
    /// precise. Fully-unbounded ("always") is the widest; a half-open bound
    /// sits between a closed window and "always".
    private static func ruleWindow(_ r: Rule) -> TimeInterval {
        if let f = r.validFrom, let t = r.validTo { return max(0, t.timeIntervalSince(f)) }
        if r.validFrom != nil || r.validTo != nil { return .greatestFiniteMagnitude / 2 }
        return .greatestFiniteMagnitude
    }

    static func matches(kind: Rule.Kind, pattern: String, value: String) -> Bool {
        if kind.supportsGlob {
            return globMatch(pattern: pattern, value: value)
        } else {
            return value.range(of: pattern, options: .caseInsensitive) != nil
        }
    }

    static func globMatch(pattern: String, value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$",
                                                   options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    /// Extracts `owner/name[/path]` from a Git remote URL.
    /// Examples:
    ///   https://github.com/forefront/foo.git → forefront/foo
    ///   git@github.com:forefront/foo.git     → forefront/foo
    static func gitSlug(fromRemote url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        // SSH form: user@host:owner/repo.git → drop user@host:
        if s.contains("@"), let at = s.firstIndex(of: "@"),
           let colon = s.firstIndex(of: ":"), at < colon {
            s = String(s[s.index(after: colon)...])
        } else if let slash = s.firstIndex(of: "/") {
            // HTTPS form: drop host
            s = String(s[s.index(after: slash)...])
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return s.isEmpty ? nil : s
    }

    /// Strips scheme and produces `host[/path]` from a Chrome tab URL. The host
    /// is lowercased; the path is preserved as-is. Returns nil for malformed input.
    static func normalizedURL(_ url: String) -> String? {
        guard let u = URLComponents(string: url),
              let host = u.host?.lowercased() else { return nil }
        let path = u.path
        return path.isEmpty ? host : host + path
    }

    /// Aggregation key for URL paths: `host[/seg1[/seg2…]]`, truncated to the
    /// first N non-empty path segments. Used by Discover to group URLs under a
    /// host into a manageable number of rows.
    static func urlPathPrefix(_ url: String, segments: Int = 2) -> String? {
        guard let u = URLComponents(string: url),
              let host = u.host?.lowercased() else { return nil }
        let parts = u.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .prefix(segments)
        if parts.isEmpty { return host }
        return host + "/" + parts.map(String.init).joined(separator: "/")
    }

    static func gitHost(fromRemote url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        if let at = s.firstIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        if let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        } else if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s.isEmpty ? nil : s
    }
}
