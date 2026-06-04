import SwiftUI

/// Calls tab — lists mic-active intervals captured by MicMonitor. Each row is
/// one continuous mic-in-use session: when it started, how long, and which
/// VoIP-style apps were running so we can guess "this was a Teams call" /
/// "this was a Slack huddle". Attribution is per-row and writes only to the
/// MicSession record — it does NOT touch sample-level attribution, since the
/// underlying foreground samples were doing other work in parallel.
/// A displayable slice of a `MicSession` — either the whole session (no
/// calendar overlap) or the leftover before/after a calendar event. Multiple
/// segments can share the same underlying `MicSession` (and therefore the same
/// attribution), but render as separate rows so a meeting overrun shows up as
/// its own ad-hoc call instead of being swallowed by the calendar block.
struct CallSegment: Identifiable, Equatable, Hashable {
    let session: MicSession
    let startedAt: Date
    /// `nil` only when this segment is the tail of an ongoing session.
    let endedAt: Date?
    let segmentIndex: Int

    var id: String { "\(session.id)#\(segmentIndex)" }

    var durationSeconds: Double? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    struct TimeRange: Equatable {
        let start: Date
        let end: Date
    }

    /// Remove the wall-clock time covered by `events` from `[start, end)` and
    /// return the non-overlapping leftovers. Segments shorter than
    /// `minimumSeconds` are dropped to avoid noise from mic flicker right at a
    /// meeting boundary.
    static func subtractEvents(from start: Date,
                               to end: Date,
                               events: [CalendarEvent],
                               minimumSeconds: TimeInterval) -> [TimeRange] {
        guard end > start else { return [] }
        let clamped: [TimeRange] = events.compactMap { e in
            let s = max(start, e.startAt)
            let t = min(end, e.endAt)
            return t > s ? TimeRange(start: s, end: t) : nil
        }.sorted { $0.start < $1.start }

        var merged: [TimeRange] = []
        for r in clamped {
            if let last = merged.last, last.end >= r.start {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end))
            } else {
                merged.append(r)
            }
        }

        var remainders: [TimeRange] = []
        var cursor = start
        for m in merged {
            if m.start > cursor {
                remainders.append(TimeRange(start: cursor, end: m.start))
            }
            cursor = max(cursor, m.end)
        }
        if cursor < end {
            remainders.append(TimeRange(start: cursor, end: end))
        }
        return remainders.filter { $0.end.timeIntervalSince($0.start) >= minimumSeconds }
    }
}

struct TeamsCallsView: View {
    @EnvironmentObject private var state: AppState
    @State private var scope: DateScope = .lastDays(7)
    @State private var segments: [CallSegment] = []
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var matcher: RuleMatcher?
    @State private var loadError: String?
    @State private var attributing: CallSegment?
    /// How many sessions were hidden because they were *fully* covered by
    /// calendar events. Surfaced in the empty state so the user knows time
    /// isn't being silently lost.
    @State private var hiddenByCalendarOverlap: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if segments.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groupedByDay, id: \.0) { (day, items) in
                            Text(dayHeader(day))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(items) { row($0) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: scope) { _, _ in reload() }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .sheet(item: $attributing) { segment in
            let attribution = effective(for: segment.session)
            CallDetailSheet(
                segment: segment,
                customers: customers,
                projects: projects,
                database: state.database,
                prefillCustomerID: attribution.customer?.id ?? "",
                prefillProjectID: attribution.project?.id ?? "",
                autoMatched: attribution.fromRule,
                onSave: { customerID, projectID, scope in
                    save(session: segment.session, customerID: customerID, projectID: projectID, scope: scope)
                },
                onClear: {
                    save(session: segment.session, customerID: nil, projectID: nil, scope: .justThis)
                }
            )
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calls").font(.system(size: 24, weight: .bold))
            HStack(alignment: .top) {
                Text("Microphone-active sessions, regardless of which app was frontmost. Tagged with whichever VoIP apps were running at the time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440, alignment: .leading)
                Spacer()
                RangeScopePicker(scope: $scope)
            }
            if scope.isDay {
                ScopeDayNavigator(scope: $scope)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var empty: some View {
        ContentUnavailableView {
            Label("No impromptu calls in this range", systemImage: "mic.slash")
        } description: {
            if hiddenByCalendarOverlap > 0 {
                Text("\(hiddenByCalendarOverlap) mic session\(hiddenByCalendarOverlap == 1 ? "" : "s") overlapping a calendar event \(hiddenByCalendarOverlap == 1 ? "is" : "are") shown under Meetings instead.")
            } else {
                Text("New ad-hoc calls will appear here. Scheduled meetings live under Meetings.")
            }
        }
    }

    @ViewBuilder
    private func row(_ seg: CallSegment) -> some View {
        let s = seg.session
        let attribution = effective(for: s)
        let customer = attribution.customer
        let project = attribution.project

        Button {
            attributing = seg
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: seg))
                    .frame(width: 22)
                    .foregroundStyle(color(for: seg))

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine(for: seg))
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(timeRange(seg))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(durationLabel(seg))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !appLabels(for: s).isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(appLabels(for: s).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if let c = customer {
                    HStack(spacing: 4) {
                        if attribution.fromRule {
                            Image(systemName: "wand.and.stars")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Auto-matched from a Slack channel rule")
                        }
                        Circle()
                            .fill(Color(hex: project?.displayColor ?? c.displayColor) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(attributionLabel(customer: c, project: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if seg.endedAt != nil {
                    UnattributedTag()
                } else {
                    Label("Ongoing", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        }
        .buttonStyle(.plain)
    }

    private func icon(for seg: CallSegment) -> String {
        if seg.endedAt == nil { return "mic.fill" }
        let apps = seg.session.voipApps
        if apps.contains(where: { $0.hasPrefix("com.microsoft.teams") }) { return "phone.fill" }
        if apps.contains(where: { $0.contains("zoom") }) { return "video.fill" }
        if apps.contains(where: { $0.contains("slack") }) { return "bubble.left.and.bubble.right.fill" }
        if apps.contains(where: { $0.contains("webex") }) { return "video.fill" }
        if apps.contains(where: { $0.contains("discord") }) { return "gamecontroller.fill" }
        if apps.contains(where: { $0.contains("facetime") }) { return "phone.fill" }
        if apps.isEmpty { return "waveform" }
        return "phone.fill"
    }

    private func color(for seg: CallSegment) -> Color {
        if seg.endedAt == nil { return .red }
        return seg.session.voipApps.isEmpty ? .gray : .green
    }

    private func titleLine(for seg: CallSegment) -> String {
        let s = seg.session
        if let p = s.participant, !p.isEmpty { return p }
        if let ch = s.slackChannel, !ch.isEmpty { return "#\(ch)" }
        let labels = appLabels(for: s)
        if labels.count == 1 { return labels[0] }
        if !labels.isEmpty { return labels.joined(separator: " / ") }
        return "Microphone activity"
    }

    private func appLabels(for s: MicSession) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for bid in s.voipApps {
            if let label = MicMonitor.displayName(forBundleID: bid), !seen.contains(label) {
                seen.insert(label)
                out.append(label)
            }
        }
        return out
    }

    private func attributionLabel(customer: Customer, project: Project?) -> String {
        if let p = project { return "\(customer.name) · \(p.name)" }
        return customer.name
    }

    private func timeRange(_ seg: CallSegment) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let start = f.string(from: seg.startedAt)
        let end = seg.endedAt.map { f.string(from: $0) } ?? "…"
        return "\(start)–\(end)"
    }

    private func durationLabel(_ seg: CallSegment) -> String {
        let secs = seg.durationSeconds ?? Date().timeIntervalSince(seg.startedAt)
        let mins = Int((secs / 60).rounded())
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    private var groupedByDay: [(Date, [CallSegment])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: segments) { cal.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.startedAt < $1.startedAt }) }
    }

    private func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    private func reload() {
        do {
            let raw = try state.database.micSessions(in: scope.interval)
            // Booked time lives under Meetings. Use the mic-extended event
            // bounds (so meeting over/undershoot is treated as part of the
            // meeting) and subtract that from each mic session. Whatever's
            // left is genuinely ad-hoc and shows up here.
            let rawEvents = try state.database.calendarEvents(in: scope.interval)
            let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: raw)
            var emitted: [CallSegment] = []
            var fullyHidden = 0
            for s in raw {
                let sStart = s.startedAt
                let sEnd = s.endedAt ?? Date()
                guard sEnd > sStart else { continue }
                let remainders = CallSegment.subtractEvents(
                    from: sStart,
                    to: sEnd,
                    events: events,
                    minimumSeconds: 30
                )
                if remainders.isEmpty {
                    fullyHidden += 1
                    continue
                }
                for (i, r) in remainders.enumerated() {
                    // Preserve the ongoing-session indicator only on the
                    // tail segment that actually reaches the live cursor.
                    let isLive = s.endedAt == nil && r.end == sEnd
                    emitted.append(CallSegment(
                        session: s,
                        startedAt: r.start,
                        endedAt: isLive ? nil : r.end,
                        segmentIndex: i
                    ))
                }
            }
            segments = emitted
            hiddenByCalendarOverlap = fullyHidden
            customers = try state.database.allCustomers()
            projects = try state.database.allProjects()
            matcher = try RuleMatcher.load(from: state.database)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Resolved attribution for a session: a manual save wins, otherwise a
    /// `slackChannel` rule auto-attributes the huddle. `fromRule` is true only
    /// for the rule-derived case, so the row can hint that it wasn't pinned.
    private func effective(for s: MicSession) -> (customer: Customer?, project: Project?, fromRule: Bool) {
        guard let result = matcher?.attribute(micSession: s) else {
            let c = s.customerID.flatMap { id in customers.first { $0.id == id } }
            let p = s.projectID.flatMap { id in projects.first { $0.id == id } }
            return (c, p, false)
        }
        return (result.customer, result.project, result.matchingRule != nil)
    }

    private func save(session: MicSession, customerID: String?, projectID: String?, scope: AttributionScope) {
        do {
            // Always pin this specific session.
            try state.database.setMicSessionAttribution(
                id: session.id,
                customerID: customerID,
                projectID: projectID
            )
            // Beyond "just this", also teach a Slack-channel rule (bounded by the
            // session's day/week, or permanent) so future huddles in that channel
            // auto-attribute. Only possible when the channel is known.
            if scope.createsRule, let cid = customerID, let channel = session.slackChannel {
                let (validFrom, validTo) = scope.bounds(reference: session.startedAt)
                let existing = try state.database.allRules()
                    .filter { $0.kind == .slackChannel && $0.pattern == channel }
                for rule in existing { try state.database.deleteRule(id: rule.id) }
                try state.database.upsert(Rule(
                    id: UUID().uuidString, customerID: cid, projectID: projectID,
                    kind: .slackChannel, pattern: channel, priority: 100, createdAt: Date(),
                    validFrom: validFrom, validTo: validTo))
            }
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct CallDetailSheet: View {
    let segment: CallSegment
    let customers: [Customer]
    let projects: [Project]
    let database: AppDatabase
    let prefillCustomerID: String
    let prefillProjectID: String
    /// True when the prefill came from a Slack-channel rule rather than a saved
    /// override — drives the "Save to pin it" hint.
    let autoMatched: Bool
    let onSave: (String?, String?, AttributionScope) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCustomerID: String = ""
    @State private var selectedProjectID: String = ""
    @State private var scope: AttributionScope = .justThis
    @State private var appBreakdown: [AppUsage] = []
    @State private var urlBreakdown: [URLUsage] = []
    @State private var loadError: String?

    private var session: MicSession { segment.session }


    struct AppUsage: Identifiable, Hashable {
        let id: String         // bundle ID
        let name: String
        let seconds: Double
    }

    struct URLUsage: Identifiable, Hashable {
        let id: String         // url prefix
        let seconds: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            attributionSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !appBreakdown.isEmpty { appsSection }
                    if !urlBreakdown.isEmpty { urlsSection }
                    if appBreakdown.isEmpty && urlBreakdown.isEmpty {
                        Text("No foreground activity captured during this call.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .onAppear {
            selectedCustomerID = prefillCustomerID
            selectedProjectID = prefillProjectID
            loadBreakdowns()
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle).font(.title2.bold())
            Text(headerDetailLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if !appLabels.isEmpty {
                Text("Running: \(appLabels.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Attribution").font(.subheadline.bold())
                if autoMatched, session.customerID == nil, let ch = session.slackChannel {
                    Label("Auto-matched from #\(ch) — Save to pin it", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            AttributionPickerSection(
                customers: customers,
                projects: projects,
                selectedCustomerID: $selectedCustomerID,
                selectedProjectID: $selectedProjectID,
                onCreateCustomer: { name in try database.createLocalCustomer(name: name) },
                onCreateProject: { customerID, name in try database.createLocalProject(customerID: customerID, name: name) },
                emptyCustomerLabel: "Unattributed",
                error: Binding(get: { loadError }, set: { loadError = $0 })
            )
            if session.slackChannel != nil {
                AttributionScopePicker(
                    scope: $scope,
                    options: [.justThis, .today, .thisWeek, .always],
                    hint: scope == .justThis
                        ? "Attributes just this call."
                        : "Also teaches a #\(session.slackChannel ?? "") rule\(scope == .always ? "" : " for \(scope.label.lowercased())").")
            }
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps in the foreground").font(.subheadline.bold())
            ForEach(appBreakdown) { a in
                HStack {
                    Image(systemName: "app")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(a.name)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    Text(formatDuration(a.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    @ViewBuilder
    private var urlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pages visited").font(.subheadline.bold())
            ForEach(urlBreakdown) { u in
                HStack {
                    Image(systemName: "link")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(u.id)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(formatDuration(u.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if session.customerID != nil {
                Button("Clear", role: .destructive) {
                    onClear()
                    dismiss()
                }
            }
            Button("Save") {
                let cid = selectedCustomerID.isEmpty ? nil : selectedCustomerID
                let pid = selectedProjectID.isEmpty ? nil : selectedProjectID
                onSave(cid, pid, scope)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCustomerID.isEmpty)
        }
    }

    private var headerTitle: String {
        if let p = session.participant, !p.isEmpty { return p }
        if let ch = session.slackChannel, !ch.isEmpty { return "#\(ch)" }
        return "Microphone activity"
    }

    private var headerDetailLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        let date = f.string(from: segment.startedAt)
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let start = tf.string(from: segment.startedAt)
        let end = segment.endedAt.map { tf.string(from: $0) } ?? "…"
        let secs = segment.durationSeconds ?? Date().timeIntervalSince(segment.startedAt)
        let mins = Int((secs / 60).rounded())
        return "\(date)  ·  \(start)–\(end)  ·  \(mins) min"
    }

    private var appLabels: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for bid in session.voipApps {
            if let label = MicMonitor.displayName(forBundleID: bid), !seen.contains(label) {
                seen.insert(label); out.append(label)
            }
        }
        return out
    }

    private func loadBreakdowns() {
        // Use "now" as the end bound for ongoing segments so users can still
        // see what was in the foreground during a call in progress.
        let endBound = segment.endedAt ?? Date()
        do {
            let samples = try database.samplesOverlapping(start: segment.startedAt, end: endBound)
            let sampleInterval = Double(AppSettings.sampleIntervalSeconds)

            var appCounts: [String: (name: String, count: Int)] = [:]
            var urlCounts: [String: Int] = [:]
            for s in samples {
                if let bid = s.appBundleID {
                    let label = s.appName ?? bid
                    let cur = appCounts[bid] ?? (name: label, count: 0)
                    appCounts[bid] = (cur.name, cur.count + 1)
                }
                if let url = s.chromeURL, let prefix = RuleMatcher.urlPathPrefix(url, segments: 2) {
                    urlCounts[prefix, default: 0] += 1
                }
            }
            appBreakdown = appCounts.map { (bid, v) in
                AppUsage(id: bid, name: v.name, seconds: Double(v.count) * sampleInterval)
            }
            .sorted { $0.seconds > $1.seconds }
            urlBreakdown = Array(urlCounts.map { URLUsage(id: $0.key, seconds: Double($0.value) * sampleInterval) }
                .sorted { $0.seconds > $1.seconds }
                .prefix(8))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
