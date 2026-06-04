import SwiftUI

// ===================================================================
// Review — the attribution triage flow (replaces Discover).
//
// Surfaces the same unattributed pool Discover did (git repos, browser
// hosts + path groups, apps, meeting series, one-off meetings) but as a
// calm one-at-a-time card stack: pick a customer/project → Confirm,
// Skip for now, or Ignore. Confirming a ruleable signal (repo / host /
// path / app) writes a reusable rule; meetings write per-series or
// per-event attribution. No AI suggestions — every card opens in
// manual-pick mode. Calls keep their own dedicated tab.
// ===================================================================

struct ReviewView: View {
    @EnvironmentObject private var state: AppState

    @State private var units: [ReviewUnit] = []
    @State private var matcher: RuleMatcher = .make(customers: [], projects: [], rules: [])
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var skipped: Set<String> = []
    @State private var processedCount: Int = 0
    @State private var loadError: String?
    @State private var didInitialLoad = false

    private var interval: DateInterval {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        return DateInterval(start: start, end: now)
    }

    private var visible: [ReviewUnit] {
        units.filter { !skipped.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .tmWallpaper()
        .onAppear { if !didInitialLoad { didInitialLoad = true; reload() } }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .alert("Database error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Review")
                .font(.system(size: 24, weight: .bold))
            Text("Attribute open time — last 7 days")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let current = visible.first {
            ScrollView {
                VStack(spacing: 22) {
                    progressBar
                    card(for: current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                    footerHint(for: current)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 28)
            }
        } else {
            doneState
        }
    }

    private var totalToReview: Int { processedCount + visible.count }

    @ViewBuilder
    private var progressBar: some View {
        let total = max(totalToReview, 1)
        let frac = Double(processedCount) / Double(total)
        VStack(spacing: 9) {
            HStack {
                (Text("\(processedCount)").bold().foregroundStyle(.primary)
                    + Text(" of \(total) reviewed"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((frac * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TM.accent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(LinearGradient(colors: [TM.accent, Color(hex: "#7a74ff") ?? TM.accent],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 8)
        }
    }

    @ViewBuilder
    private func footerHint(for unit: ReviewUnit) -> some View {
        Text(unit.isHostGroup
             ? "Assign each path — the shared host itself is never attributed as a whole."
             : (unit.createsRule
                ? "Confirming teaches a rule so this attributes automatically next time."
                : "Attributed on its own — no rule is created."))
            .font(.caption).foregroundStyle(.tertiary)
    }

    // MARK: - Done state

    @ViewBuilder
    private var doneState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(LinearGradient(colors: [TM.positive, Color(hex: "#0ea371") ?? TM.positive],
                                           startPoint: .top, endPoint: .bottom), in: Circle())
                .shadow(color: TM.positive.opacity(0.5), radius: 18, y: 8)
            Text("You're all caught up").font(.system(size: 26, weight: .bold))
            Text(skipped.isEmpty
                 ? "Every captured signal in the last 7 days has a home. Your report is ready."
                 : "Nothing left except what you skipped. Skipped items stay open for next time.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if !skipped.isEmpty {
                Button("Review \(skipped.count) skipped") {
                    withAnimation { skipped.removeAll() }
                }
                .buttonStyle(.bordered)
            }
            Button {
                state.selectedSection = .weeklyReport
            } label: {
                Label("See the report", systemImage: "chart.bar.doc.horizontal.fill")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card

    @ViewBuilder
    private func card(for unit: ReviewUnit) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: unit.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 3) {
                    Text(unit.kindLabel.uppercased())
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    Text(unit.title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    if let sub = unit.subtitle {
                        Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatHours(unit.totalSeconds))
                        .font(.system(size: 20, weight: .bold)).monospacedDigit()
                    Text(unit.isHostGroup ? "\(unit.hostPaths.count) to sort" : "this week")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            }

            if unit.isHostGroup {
                VStack(spacing: 8) {
                    ForEach(unit.hostPaths) { path in
                        PathAssignRow(
                            path: path,
                            customers: customers,
                            projects: projects,
                            onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                            onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                            onConfirm: { cust, proj in assignSignal(path, customerID: cust, projectID: proj) }
                        )
                    }
                }
            } else {
                InlineAssign(
                    customers: customers,
                    projects: projects,
                    confirmLabel: "Confirm",
                    onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                    onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                    onConfirm: { cust, proj in confirm(unit, customerID: cust, projectID: proj) }
                )
                if case .signal(let s) = unit, s.kind == .gitRepoSlug {
                    Label("Future commits to this repo attribute here automatically.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Divider()
            HStack {
                Button("Skip for now") { skip(unit) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut("s", modifiers: [])
                Spacer()
                if unit.canIgnore {
                    Button("Ignore — don't ask again") { ignore(unit) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(24)
        .glassCard(radius: 22)
    }

    // MARK: - Actions

    private func confirm(_ unit: ReviewUnit, customerID: String, projectID: String?) {
        switch unit {
        case .signal(let s):
            assignSignal(s, customerID: customerID, projectID: projectID)
        case .hostGroup:
            break // host group confirms per path
        case .series(let s):
            write { try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: customerID, projectID: projectID, isIgnored: false) }
        case .event(let e):
            write { try state.database.setCalendarEventAttribution(eventID: e.id, customerID: customerID, projectID: projectID) }
        }
    }

    /// Writes a rule for a signal (repo / app / host / path), matching the
    /// behaviour Discover used: replace any existing rule with the same
    /// (kind, pattern) then upsert at priority 100.
    private func assignSignal(_ signal: AppDatabase.SignalAggregate, customerID: String, projectID: String?) {
        let kind = ruleKind(signal.kind)
        let pattern: String = (signal.kind == .urlPath && !signal.value.contains("*"))
            ? signal.value + "*" : signal.value
        write {
            let existing = try state.database.allRules().filter { $0.kind == kind && $0.pattern == pattern }
            for rule in existing { try state.database.deleteRule(id: rule.id) }
            try state.database.upsert(Rule(
                id: UUID().uuidString, customerID: customerID, projectID: projectID,
                kind: kind, pattern: pattern, priority: 100, createdAt: Date()))
        }
    }

    private func skip(_ unit: ReviewUnit) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            skipped.insert(unit.id)
        }
    }

    private func ignore(_ unit: ReviewUnit) {
        switch unit {
        case .signal(let s):
            if let hk = hiddenKind(s.kind) {
                write { try state.database.hideSignal(kind: hk, value: s.value) }
            }
        case .hostGroup(let host, _):
            write { try state.database.hideSignal(kind: .urlHost, value: host.value) }
        case .series(let s):
            write { try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: nil, projectID: nil, isIgnored: true) }
        case .event(let e):
            write { try state.database.setCalendarEventIgnored(eventID: e.id, isIgnored: true) }
        }
    }

    /// Runs a DB mutation, counts it as one processed item, and reloads.
    private func write(_ body: () throws -> Void) {
        do {
            try body()
            processedCount += 1
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reload() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func hiddenKind(_ k: AppDatabase.SignalAggregate.Kind) -> HiddenSignal.Kind? {
        switch k {
        case .appBundleID: return .appBundleID
        case .urlHost:     return .urlHost
        default:           return nil
        }
    }

    private func ruleKind(_ k: AppDatabase.SignalAggregate.Kind) -> Rule.Kind {
        switch k {
        case .gitRepoSlug: return .gitRepoSlug
        case .urlHost:     return .urlHost
        case .urlPath:     return .urlPath
        case .appBundleID: return .appBundleID
        }
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        if hours < 1 { return String(format: "%.0f min", seconds / 60.0) }
        return String(format: "%.1f h", hours)
    }

    // MARK: - Reload / queue building

    private func reload() {
        do {
            let interval = self.interval
            let sampleInterval = AppSettings.sampleIntervalSeconds
            let idleThreshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)

            var baseAggs = try state.database.signalAggregates(in: interval, sampleIntervalSeconds: sampleInterval)
            // Fold Claude session activity into git-repo aggregates (as Discover does).
            let sessionRepos = try state.database.sessionRepoAggregates(in: interval, idleThresholdSeconds: idleThreshold)
            if !sessionRepos.isEmpty {
                var bySlug: [String: Double] = [:]
                var others: [AppDatabase.SignalAggregate] = []
                for agg in baseAggs {
                    if agg.kind == .gitRepoSlug { bySlug[agg.value, default: 0] += agg.totalSeconds }
                    else { others.append(agg) }
                }
                for s in sessionRepos { bySlug[s.value, default: 0] += s.totalSeconds }
                baseAggs = others + bySlug.map { AppDatabase.SignalAggregate(kind: .gitRepoSlug, value: $0.key, totalSeconds: $0.value) }
            }

            let allCustomers = try state.database.allCustomers()
            let allProjects = try state.database.allProjects()
            let rules = try state.database.allRules()
            let seriesAttrs = try state.database.allMeetingSeriesAttributions()
            let m = RuleMatcher.make(customers: allCustomers, projects: allProjects, rules: rules, series: seriesAttrs)
            let hidden = try state.database.allHiddenSignals()
            let hiddenApps = Set(hidden.filter { $0.kind == .appBundleID }.map { $0.value })
            let hiddenHosts = Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })

            let series = try state.database.meetingSeriesAggregates(in: interval)
            let oneOffs = try state.database.oneOffMeetingAggregates(in: interval)
            let seriesByID = Dictionary(uniqueKeysWithValues: seriesAttrs.map { ($0.seriesMasterID, $0) })

            var built: [ReviewUnit] = []

            for agg in baseAggs {
                switch agg.kind {
                case .gitRepoSlug:
                    if m.attribute(kind: .gitRepoSlug, value: agg.value).customer == nil {
                        built.append(.signal(agg))
                    }
                case .appBundleID:
                    if hiddenApps.contains(agg.value) { continue }
                    if m.attribute(kind: .appBundleID, value: agg.value).customer == nil {
                        built.append(.signal(agg))
                    }
                case .urlHost:
                    if hiddenHosts.contains(agg.value) { continue }
                    if m.attribute(kind: .urlHost, value: agg.value).customer != nil { continue }
                    let paths = (try? state.database.urlPathAggregates(forHost: agg.value, in: interval, sampleIntervalSeconds: sampleInterval)) ?? []
                    let openPaths = paths.filter { m.attribute(kind: .urlPath, value: $0.value).customer == nil }
                    if openPaths.count >= 1 {
                        built.append(.hostGroup(host: agg, paths: openPaths))
                    } else if paths.isEmpty {
                        built.append(.signal(agg))   // host with no path detail → assign whole host
                    }
                case .urlPath:
                    break
                }
            }

            for s in series {
                let attr = seriesByID[s.seriesMasterID]
                if attr?.isIgnored == true { continue }
                if attr?.customerID == nil { built.append(.series(s)) }
            }
            for e in oneOffs where e.customerID == nil {
                built.append(.event(e))
            }

            built.sort { $0.totalSeconds > $1.totalSeconds }

            self.matcher = m
            self.customers = allCustomers
            self.projects = allProjects
            self.units = built
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Review unit model

enum ReviewUnit: Identifiable {
    case signal(AppDatabase.SignalAggregate)
    case hostGroup(host: AppDatabase.SignalAggregate, paths: [AppDatabase.SignalAggregate])
    case series(AppDatabase.MeetingSeriesAggregate)
    case event(CalendarEvent)

    var id: String {
        switch self {
        case .signal(let s):       return "sig:\(s.kind):\(s.value)"
        case .hostGroup(let h, _): return "host:\(h.value)"
        case .series(let s):       return "series:\(s.seriesMasterID)"
        case .event(let e):        return "event:\(e.id)"
        }
    }

    var isHostGroup: Bool { if case .hostGroup = self { return true }; return false }

    var hostPaths: [AppDatabase.SignalAggregate] {
        if case .hostGroup(_, let paths) = self { return paths }; return []
    }

    var totalSeconds: Double {
        switch self {
        case .signal(let s):        return s.totalSeconds
        case .hostGroup(_, let ps): return ps.reduce(0) { $0 + $1.totalSeconds }
        case .series(let s):        return s.totalSeconds
        case .event(let e):         return max(0, e.endAt.timeIntervalSince(e.startAt))
        }
    }

    var title: String {
        switch self {
        case .signal(let s):       return s.value
        case .hostGroup(let h, _): return h.value
        case .series(let s):       return s.sampleSubject
        case .event(let e):        return e.subject.isEmpty ? "(no subject)" : e.subject
        }
    }

    var subtitle: String? {
        switch self {
        case .signal:        return nil
        case .hostGroup:     return "Shared browser host"
        case .series(let s): return "Recurring series · \(s.occurrenceCount) occurrences"
        case .event(let e):
            let df = DateFormatter(); df.dateFormat = "EEE d MMM HH:mm"
            return df.string(from: e.startAt)
        }
    }

    var kindLabel: String {
        switch self {
        case .signal(let s):
            switch s.kind {
            case .gitRepoSlug: return "Git repo"
            case .urlHost:     return "Browser host"
            case .urlPath:     return "Browser URL"
            case .appBundleID: return "App"
            }
        case .hostGroup: return "Shared host"
        case .series:    return "Meeting series"
        case .event:     return "Meeting"
        }
    }

    var systemImage: String {
        switch self {
        case .signal(let s):
            switch s.kind {
            case .gitRepoSlug: return "chevron.left.forwardslash.chevron.right"
            case .urlHost:     return "globe"
            case .urlPath:     return "link"
            case .appBundleID: return "app"
            }
        case .hostGroup: return "globe"
        case .series:    return "repeat"
        case .event:     return "calendar"
        }
    }

    /// Confirming this unit writes a reusable rule (vs a one-off attribution).
    var createsRule: Bool {
        switch self {
        case .signal, .hostGroup, .series: return true
        case .event:                       return false
        }
    }

    /// Whether "Ignore — don't ask again" applies. Repos can only be skipped.
    var canIgnore: Bool {
        switch self {
        case .signal(let s): return s.kind == .urlHost || s.kind == .appBundleID
        case .hostGroup, .series, .event: return true
        }
    }
}

// MARK: - Inline assign control

/// Customer/project picker + Confirm, owning its own selection. Used for
/// single-card units and for each row of a host group.
private struct InlineAssign: View {
    let customers: [Customer]
    let projects: [Project]
    var confirmLabel: String
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    let onConfirm: (String, String?) -> Void

    @State private var customerID = ""
    @State private var projectID = ""
    @State private var error: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AttributionPickerSection(
                customers: customers, projects: projects,
                selectedCustomerID: $customerID, selectedProjectID: $projectID,
                onCreateCustomer: onCreateCustomer, onCreateProject: onCreateProject,
                showsLabel: false, error: $error
            )
            Button(confirmLabel) {
                onConfirm(customerID, projectID.isEmpty ? nil : projectID)
            }
            .buttonStyle(.borderedProminent)
            .disabled(customerID.isEmpty)
        }
    }
}

/// One path row inside a host group — compact picker + Assign.
private struct PathAssignRow: View {
    let path: AppDatabase.SignalAggregate
    let customers: [Customer]
    let projects: [Project]
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    let onConfirm: (String, String?) -> Void

    var pathLabel: String {
        if let slash = path.value.firstIndex(of: "/") { return String(path.value[slash...]) }
        return path.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pathLabel).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: path.totalSeconds < 3600 ? "%.0f min" : "%.1f h",
                            path.totalSeconds < 3600 ? path.totalSeconds / 60 : path.totalSeconds / 3600))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            InlineAssign(
                customers: customers, projects: projects, confirmLabel: "Assign",
                onCreateCustomer: onCreateCustomer, onCreateProject: onCreateProject,
                onConfirm: onConfirm
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}
