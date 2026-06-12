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

    // A *stable snapshot* of the open items for the period. Actions don't remove
    // items — they record a resolution — so you can navigate back to anything you
    // already attributed/ignored (and undo it), and stay on a host card while
    // assigning its paths one by one.
    @State private var units: [ReviewUnit] = []
    @State private var resolved: [String: String] = [:]      // unit id → result label
    @State private var pathResolved: [String: String] = [:]  // path value → result label
    @State private var matcher: RuleMatcher = .make(customers: [], projects: [], rules: [])
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var cursor: Int = 0          // position in the snapshot
    @State private var loadError: String?
    @State private var didInitialLoad = false
    @State private var scope: AttrScope = .always
    @State private var weekStart: Date = Calendar.weekStartingMonday().currentWeekInterval().start
    @State private var selectedDay: Date? = nil    // nil = whole selected week

    private let calendar = Calendar.weekStartingMonday()

    /// `.always` writes a permanent rule; `.period` writes a temporary rule
    /// bounded to the currently-selected week (or day), so the same signal can
    /// attribute elsewhere in a different period.
    enum AttrScope: String, CaseIterable, Identifiable {
        case always, period
        var id: String { rawValue }
    }

    private var week: DateInterval {
        DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
    }

    /// The activity window the review reflects: a single day if one is picked,
    /// otherwise the whole selected week.
    private var period: DateInterval {
        if let day = selectedDay {
            let s = calendar.startOfDay(for: day)
            return DateInterval(start: s, end: calendar.date(byAdding: .day, value: 1, to: s) ?? s)
        }
        return week
    }

    private var interval: DateInterval { period }

    /// (validFrom, validTo) for a rule under the current scope.
    private var scopeBounds: (Date?, Date?) {
        scope == .always ? (nil, nil) : (period.start, period.end)
    }

    /// "this week" / "Wed 4 Jun" — used in the scope label + hint.
    private var periodLabel: String {
        if let day = selectedDay { return DateFormatting.weekdayDayShortMonth.string(from: day) }
        return "this week"
    }

    private var isCurrentWeek: Bool { weekStart == calendar.currentWeekInterval().start }

    /// The card currently under the cursor (nil = stepped past the end → done).
    private var current: ReviewUnit? {
        cursor >= 0 && cursor < units.count ? units[cursor] : nil
    }

    /// A unit is resolved once it's attributed/ignored — for a host group, once
    /// every one of its paths is assigned/ignored (or the whole host is set).
    private func isResolved(_ unit: ReviewUnit) -> Bool {
        if resolved[unit.id] != nil { return true }
        if unit.isHostGroup {
            return !unit.hostPaths.isEmpty && unit.hostPaths.allSatisfy { pathResolved[$0.value] != nil }
        }
        return false
    }
    private var resolvedCount: Int { units.filter { isResolved($0) }.count }

    /// If the menu bar asked Review to land on a specific week, snap to it and
    /// clear the request. Changing `weekStart` triggers a reload via onChange.
    /// Returns whether a target was consumed.
    @discardableResult
    private func consumeReviewTarget() -> Bool {
        guard let target = state.reviewTargetWeekStart else { return false }
        state.reviewTargetWeekStart = nil
        selectedDay = nil
        if target != weekStart { weekStart = target }
        return true
    }

    /// Scan the recent weeks for residual backlog and jump to the oldest one
    /// with open items (falling back to a normal load of the current week when
    /// everything is clean). Runs off the main actor; if `weekStart` ends up
    /// changing, the onChange handler does the reload.
    private func landOnOldestOpenWeek() {
        let db = state.database
        let now = Date()
        let sampleInterval = AppSettings.sampleIntervalSeconds
        let idleMinutes = AppSettings.claudeIdleThresholdMinutes
        let reviewMin = AppSettings.reviewMinMinutes
        Task { @MainActor in
            let oldest = await Task.detached(priority: .userInitiated) { () -> Date? in
                (try? ReviewQueue.rolling(
                    database: db, now: now,
                    weeksBack: ReviewQueue.defaultBacklogWeeksBack,
                    sampleIntervalSeconds: sampleInterval,
                    idleThresholdSeconds: TimeInterval(idleMinutes * 60),
                    minMinutes: reviewMin))?.oldestOpenWeekStart
            }.value
            if let oldest, oldest != weekStart {
                weekStart = oldest   // onChange(weekStart) → reload
            } else {
                reload()
            }
        }
    }

    private func goBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { cursor = max(0, cursor - 1) }
    }
    private func goForward() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { cursor = min(units.count, cursor + 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            let hadTarget = consumeReviewTarget()
            if !didInitialLoad {
                didInitialLoad = true
                // A fresh entry (sidebar click, window reopen) lands on the
                // oldest week that still has open items — same window the
                // menu-bar glance scans — so you clear the backlog tail first.
                // An explicit target (from the menu bar) already picked the
                // week, so just load it.
                if hadTarget { reload() } else { landOnOldestOpenWeek() }
            }
        }
        .onChange(of: state.reviewTargetWeekStart) { _, _ in _ = consumeReviewTarget() }
        .onChange(of: weekStart) { _, _ in reload() }
        .onChange(of: selectedDay) { _, _ in reload() }
        // Refresh when new activity lands, but only before the user has started
        // acting — so a live snapshot doesn't wipe in-session resolutions/cursor.
        .onChange(of: state.sampleCount) { _, _ in
            if cursor == 0 && resolved.isEmpty && pathResolved.isEmpty { reload() }
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review").font(.system(size: 24, weight: .bold))
                    Text("Attribute open time — \(weekTitle)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                DateNavigator(
                    title: isCurrentWeek ? "This week" : weekTitle,
                    nowLabel: "This week",
                    prevHelp: "Previous week", nextHelp: "Next week",
                    titleMinWidth: 150,
                    nowDisabled: isCurrentWeek,
                    onPrev: { weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart },
                    onNext: { weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart },
                    onNow: { weekStart = calendar.currentWeekInterval().start }
                )
            }
            dayChips
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    private var weekTitle: String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(DateFormatting.dayMonth.string(from: weekStart)) – \(DateFormatting.dayMonth.string(from: end))"
    }

    /// "Whole week" + the 7 weekdays of the selected week. Picking a day narrows
    /// the review (and "Just this period" → that day).
    @ViewBuilder
    private var dayChips: some View {
        let days = calendar.days(in: week)
        HStack(spacing: 6) {
            chip(title: "Whole week", active: selectedDay == nil) { selectedDay = nil }
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                chip(title: DateFormatting.weekdayShort.string(from: day),
                     active: selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false) {
                    selectedDay = day
                }
            }
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(active ? TM.accent : Color.primary.opacity(0.06),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let current {
            ScrollView {
                VStack(spacing: 18) {
                    progressBar
                        .frame(maxWidth: 620)
                    HStack(alignment: .top, spacing: 16) {
                        navArrow(systemImage: "chevron.left", disabled: cursor == 0, action: goBack)
                            .padding(.top, 30)
                        VStack(spacing: 14) {
                            card(for: current)
                                .id(current.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                            footerHint(for: current)
                        }
                        .frame(maxWidth: 560)
                        navArrow(systemImage: "chevron.right", disabled: false, action: goForward)
                            .padding(.top, 30)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 24)
            }
        } else {
            doneState
        }
    }

    /// Large circular navigation arrow flanking the review card.
    private func navArrow(systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())   // whole circle is clickable, not just the glyph
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(systemImage.contains("left") ? "Previous item" : "Next item")
    }

    private var reviewedCount: Int { resolvedCount }
    private var totalToReview: Int { units.count }

    @ViewBuilder
    private var progressBar: some View {
        let total = max(totalToReview, 1)
        let frac = Double(reviewedCount) / Double(total)
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Text("\(reviewedCount) of \(total) reviewed")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Text("item \(min(cursor + 1, total)) · \(Int((frac * 100).rounded()))%")
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
            let openCount = units.filter { !isResolved($0) }.count
            Text(openCount == 0 ? "You're all caught up" : "Reached the end").font(.system(size: 26, weight: .bold))
            Text(openCount == 0
                 ? "Every captured item for \(periodLabel) has a home. Your report is ready."
                 : "\(openCount) item\(openCount == 1 ? "" : "s") still open — you skipped past them. Jump back to attribute them.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if openCount > 0 {
                Button("Back to \(openCount) open") {
                    withAnimation {
                        cursor = units.firstIndex { !isResolved($0) } ?? 0
                    }
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
                    Text(unit.isHostGroup ? "\(unit.hostPaths.count) to sort" : periodLabel)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            }

            detailPanel(for: unit)

            if let label = resolved[unit.id], !unit.isHostGroup {
                // Already attributed/ignored this session → show result + undo.
                resolvedBanner(label) { clear(unit) }
            } else if unit.isHostGroup, case .hostGroup(let host, _) = unit {
                if let label = resolved[unit.id] {
                    resolvedBanner(label) { clear(unit) }
                } else {
                    hostGroupBody(unit, host: host)
                }
            } else {
                if showsScopePicker(unit) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $scope) {
                            Text("Always").tag(AttrScope.always)
                            Text("Just \(periodLabel)").tag(AttrScope.period)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(scopeHint).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                InlineAssign(
                    customers: customers,
                    projects: projects,
                    confirmLabel: "Confirm",
                    onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                    onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                    onConfirm: { cust, proj in confirm(unit, customerID: cust, projectID: proj) }
                )
                if case .signal(let s) = unit, s.kind == .gitRepoSlug, scope == .always {
                    Label("Future commits to this repo attribute here automatically.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if unit.canIgnore {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Ignore — don't ask again") { ignore(unit) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text("Ignore hides it permanently — the Always / Just-this-period choice only affects attribution.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(24)
        .glassCard(radius: 22)
    }

    // MARK: - Detail panel (meetings & calls)

    /// Extra context shown under the card header so meetings and calls aren't a
    /// bare subject + time — attendee domains and organizer in particular are
    /// the strongest hints for which customer a meeting belongs to.
    @ViewBuilder
    private func detailPanel(for unit: ReviewUnit) -> some View {
        switch unit {
        case .event(let e):         meetingEventDetail(e)
        case .series(let s):        meetingSeriesDetail(s)
        case .call(let session, _): callDetail(session)
        case .signal, .hostGroup:   EmptyView()
        }
    }

    private func detailRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func meetingEventDetail(_ e: CalendarEvent) -> some View {
        detailCard {
            detailRow("clock", eventTimeRange(e))
            if let org = (e.organizerName?.isEmpty == false ? e.organizerName : e.organizerEmail), !org.isEmpty {
                detailRow("person.crop.circle", "Organizer: \(org)")
            }
            if !e.attendeeDomains.isEmpty {
                detailRow("at", "Attendees from \(e.attendeeDomains.joined(separator: ", "))")
            }
            if e.isOnlineMeeting {
                detailRow("video", onlineLabel(e))
            } else if let loc = e.location, !loc.isEmpty {
                detailRow("mappin.and.ellipse", loc)
            }
            if let rsvp = rsvpLabel(e.rsvpStatus) {
                detailRow("checkmark.circle", rsvp)
            }
            if let body = e.bodyPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                Text(body).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(3)
                    .padding(.top, 1)
            }
        }
    }

    @ViewBuilder
    private func meetingSeriesDetail(_ s: AppDatabase.MeetingSeriesAggregate) -> some View {
        let avgMin = Int((s.totalSeconds / Double(max(1, s.occurrenceCount)) / 60).rounded())
        detailCard {
            detailRow("repeat", "\(s.occurrenceCount) occurrence\(s.occurrenceCount == 1 ? "" : "s") this \(selectedDay == nil ? "week" : "day")")
            detailRow("calendar", seriesSpan(s))
            detailRow("clock", "~\(avgMin) min each")
        }
    }

    @ViewBuilder
    private func callDetail(_ s: MicSession) -> some View {
        let timeRange = callTimeRange(s)
        let apps = ReviewUnit.callApps(s)
        detailCard {
            if let timeRange { detailRow("clock", timeRange) }
            if !apps.isEmpty { detailRow("app", "Running: \(apps.joined(separator: ", "))") }
            if let p = s.participant, !p.isEmpty { detailRow("person.crop.circle", "With \(p)") }
            if let ch = s.slackChannel, !ch.isEmpty {
                detailRow("number", "Huddle in #\(ch)")
            } else {
                detailRow("info.circle", "Ad-hoc call — assigns just this session")
            }
        }
    }

    private func seriesSpan(_ s: AppDatabase.MeetingSeriesAggregate) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE d MMM"
        if s.occurrenceCount > 1 {
            return "\(df.string(from: s.firstStartAt)) – \(df.string(from: s.lastStartAt))"
        }
        return df.string(from: s.firstStartAt)
    }

    private func callTimeRange(_ s: MicSession) -> String? {
        guard let end = s.endedAt else { return nil }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        return "\(f.string(from: s.startedAt))–\(tf.string(from: end))"
    }

    private func eventTimeRange(_ e: CalendarEvent) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE d MMM"
        if e.isAllDay { return "\(df.string(from: e.startAt)) · All day" }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        return "\(df.string(from: e.startAt)) · \(tf.string(from: e.startAt))–\(tf.string(from: e.endAt))"
    }

    private func onlineLabel(_ e: CalendarEvent) -> String {
        switch e.onlineMeetingProvider?.lowercased() {
        case .some(let p) where p.contains("teams"): return "Microsoft Teams meeting"
        case .some(let p) where p.contains("zoom"):  return "Zoom meeting"
        case .some(let p) where p.contains("meet"):  return "Google Meet"
        default: return "Online meeting"
        }
    }

    private func rsvpLabel(_ status: String) -> String? {
        switch status {
        case "accepted":            return "You accepted"
        case "tentativelyAccepted": return "You marked tentative"
        case "declined":            return "You declined"
        case "organizer":           return "You organized this"
        case "notResponded":        return "No response yet"
        default:                    return nil
        }
    }

    @ViewBuilder
    private func resolvedBanner(_ label: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(TM.positive)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 15, weight: .semibold))
                Text("Saved this session").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear", role: .destructive, action: onClear)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func hostGroupBody(_ unit: ReviewUnit, host: AppDatabase.SignalAggregate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsScopePicker(unit) {
                Picker("", selection: $scope) {
                    Text("Always").tag(AttrScope.always)
                    Text("Just \(periodLabel)").tag(AttrScope.period)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("ASSIGN ENTIRE HOST").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                InlineAssign(
                    customers: customers, projects: projects, confirmLabel: "Assign host",
                    onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                    onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                    onConfirm: { cust, proj in assignSignal(host, customerID: cust, projectID: proj, markUnit: unit.id) }
                )
                Text(scope == .always
                     ? "All current and future paths under \(host.value) attribute here."
                     : "Paths under \(host.value) during \(periodLabel) attribute here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Divider()
            Text("OR ASSIGN INDIVIDUAL PATHS").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                ForEach(unit.hostPaths) { path in
                    PathAssignRow(
                        path: path,
                        resolvedLabel: pathResolved[path.value],
                        customers: customers,
                        projects: projects,
                        onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                        onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                        onConfirm: { cust, proj in assignPath(path, customerID: cust, projectID: proj) },
                        onIgnore: { ignorePath(path) },
                        onClear: { clearPath(path) }
                    )
                }
            }
            Button("Ignore host — don't ask again") { ignore(unit) }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 13, weight: .medium))
        }
    }

    /// Scope picker applies to rule-creating signals (repos / URLs / hosts),
    /// not meetings (series attribution isn't time-bounded here).
    private func showsScopePicker(_ unit: ReviewUnit) -> Bool {
        switch unit {
        case .signal, .hostGroup: return true
        case .series, .event:     return false
        case .call(let s, _):     return s.slackChannel != nil   // only a channel huddle can teach a rule
        }
    }

    private var scopeHint: String {
        switch scope {
        case .always: return "Creates a rule — future activity auto-attributes here."
        case .period: return "Attributes only \(periodLabel)'s matching activity; other periods can go elsewhere."
        }
    }

    // MARK: - Actions
    //
    // Actions mutate the DB and record an in-session resolution (no reload /
    // removal), so the snapshot is stable and any item can be revisited & undone.

    /// Human label for the resolved banner / tags.
    private func attrLabel(_ customerID: String, _ projectID: String?) -> String {
        let c = customers.first { $0.id == customerID }?.name ?? customerID
        if let pid = projectID, let p = projects.first(where: { $0.id == pid })?.name { return "\(c) · \(p)" }
        return c
    }

    private func confirm(_ unit: ReviewUnit, customerID: String, projectID: String?) {
        switch unit {
        case .signal(let s):
            if run({ try writeSignalRule(s, customerID: customerID, projectID: projectID) }) {
                resolved[unit.id] = attrLabel(customerID, projectID); advance()
            }
        case .hostGroup:
            break // host group handled per path / whole-host
        case .series(let s):
            if run({ try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: customerID, projectID: projectID, isIgnored: false) }) {
                resolved[unit.id] = attrLabel(customerID, projectID); advance()
            }
        case .event(let e):
            if run({ try state.database.setCalendarEventAttribution(eventID: e.id, customerID: customerID, projectID: projectID) }) {
                resolved[unit.id] = attrLabel(customerID, projectID); advance()
            }
        case .call(let session, _):
            // Pin this session; if it carries a Slack channel, also teach a
            // channel rule (bounded under "Just this period", permanent under
            // "Always") so future huddles in that channel auto-attribute.
            if run({
                try state.database.setMicSessionAttribution(id: session.id, customerID: customerID, projectID: projectID)
                if let channel = session.slackChannel {
                    let (validFrom, validTo) = scopeBounds
                    try state.database.upsertReplacingWindow(Rule(
                        id: UUID().uuidString, customerID: customerID, projectID: projectID,
                        kind: .slackChannel, pattern: channel, priority: 100, createdAt: Date(),
                        validFrom: validFrom, validTo: validTo))
                }
            }) {
                resolved[unit.id] = attrLabel(customerID, projectID); advance()
            }
        }
    }

    /// Whole-host or single-signal rule assignment (advances).
    private func assignSignal(_ signal: AppDatabase.SignalAggregate, customerID: String, projectID: String?, markUnit: String) {
        if run({ try writeSignalRule(signal, customerID: customerID, projectID: projectID) }) {
            resolved[markUnit] = attrLabel(customerID, projectID); advance()
        }
    }

    /// A single path inside a host group — records path resolution, stays on card.
    private func assignPath(_ path: AppDatabase.SignalAggregate, customerID: String, projectID: String?) {
        if run({ try writeSignalRule(path, customerID: customerID, projectID: projectID) }) {
            pathResolved[path.value] = attrLabel(customerID, projectID)
        }
    }

    private func ignorePath(_ path: AppDatabase.SignalAggregate) {
        if run({ try state.database.hideSignal(kind: .urlPath, value: path.value) }) {
            pathResolved[path.value] = "Ignored"
        }
    }

    private func clearPath(_ path: AppDatabase.SignalAggregate) {
        let kind = ruleKind(path.kind)
        let pattern = (path.kind == .urlPath && !path.value.contains("*")) ? path.value + "*" : path.value
        let ok = run {
            for r in try state.database.allRules().filter({ $0.kind == kind && $0.pattern == pattern }) {
                try state.database.deleteRule(id: r.id)
            }
            for h in try state.database.allHiddenSignals().filter({ $0.kind == .urlPath && $0.value == path.value }) {
                try state.database.unhide(id: h.id)
            }
        }
        if ok { pathResolved[path.value] = nil }
    }

    private func ignore(_ unit: ReviewUnit) {
        let ok: Bool
        switch unit {
        case .signal(let s):
            if let hk = hiddenKind(s.kind) { ok = run { try state.database.hideSignal(kind: hk, value: s.value) } }
            else { ok = false }
        case .hostGroup(let host, _):
            ok = run { try state.database.hideSignal(kind: .urlHost, value: host.value) }
        case .series(let s):
            ok = run { try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: nil, projectID: nil, isIgnored: true) }
        case .event(let e):
            ok = run { try state.database.setCalendarEventIgnored(eventID: e.id, isIgnored: true) }
        case .call(let session, _):
            ok = run { try state.database.setMicSessionIgnored(id: session.id, isIgnored: true) }
        }
        if ok { resolved[unit.id] = "Ignored"; advance() }
    }

    /// Undo a resolved unit — delete its rule / clear its attribution / un-ignore.
    private func clear(_ unit: ReviewUnit) {
        let ok: Bool
        switch unit {
        case .signal(let s):
            let kind = ruleKind(s.kind)
            let pattern = (s.kind == .urlPath && !s.value.contains("*")) ? s.value + "*" : s.value
            ok = run {
                for r in try state.database.allRules().filter({ $0.kind == kind && $0.pattern == pattern }) {
                    try state.database.deleteRule(id: r.id)
                }
                if let hk = hiddenKind(s.kind) {
                    for h in try state.database.allHiddenSignals().filter({ $0.kind == hk && $0.value == s.value }) {
                        try state.database.unhide(id: h.id)
                    }
                }
            }
        case .hostGroup(let host, _):
            ok = run {
                // whole-host rule + host hide
                for r in try state.database.allRules().filter({ $0.kind == .urlHost && $0.pattern == host.value }) {
                    try state.database.deleteRule(id: r.id)
                }
                for h in try state.database.allHiddenSignals().filter({ $0.kind == .urlHost && $0.value == host.value }) {
                    try state.database.unhide(id: h.id)
                }
            }
        case .series(let s):
            ok = run { try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: nil, projectID: nil, isIgnored: false) }
        case .event(let e):
            ok = run {
                try state.database.setCalendarEventAttribution(eventID: e.id, customerID: nil, projectID: nil)
                try state.database.setCalendarEventIgnored(eventID: e.id, isIgnored: false)
            }
        case .call(let session, _):
            ok = run {
                try state.database.setMicSessionAttribution(id: session.id, customerID: nil, projectID: nil)
                try state.database.setMicSessionIgnored(id: session.id, isIgnored: false)
                if let channel = session.slackChannel {
                    for r in try state.database.allRules().filter({ $0.kind == .slackChannel && $0.pattern == channel }) {
                        try state.database.deleteRule(id: r.id)
                    }
                }
            }
        }
        if ok { resolved[unit.id] = nil }
    }

    /// Shared rule writer: replace any rule with the same (kind, pattern), then
    /// upsert at priority 100 with the current scope's validity window.
    private func writeSignalRule(_ signal: AppDatabase.SignalAggregate, customerID: String, projectID: String?) throws {
        let kind = ruleKind(signal.kind)
        let pattern = (signal.kind == .urlPath && !signal.value.contains("*")) ? signal.value + "*" : signal.value
        let (validFrom, validTo) = scopeBounds
        try state.database.upsertReplacingWindow(Rule(
            id: UUID().uuidString, customerID: customerID, projectID: projectID,
            kind: kind, pattern: pattern, priority: 100, createdAt: Date(),
            validFrom: validFrom, validTo: validTo))
    }

    private func advance() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            cursor = min(units.count, cursor + 1)
        }
    }

    /// Runs a DB mutation, returning whether it succeeded so callers only update
    /// in-session UI state on success. Surfaces errors; does NOT reload the snapshot.
    @discardableResult
    private func run(_ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch { loadError = error.localizedDescription; return false }
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
            // Build the triage queue via the shared builder so the Review screen
            // and the report/menu-bar "to review" indicator always agree.
            let built = try ReviewQueue.build(
                database: state.database,
                interval: interval,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds,
                idleThresholdSeconds: TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60),
                minMinutes: AppSettings.reviewMinMinutes
            )

            // The card UI also needs a matcher + customer/project lists for the
            // pickers and resolved-state checks.
            let allCustomers = try state.database.allCustomers()
            let allProjects = try state.database.allProjects()
            let rules = try state.database.allRules()
            let seriesAttrs = try state.database.allMeetingSeriesAttributions()
            let m = RuleMatcher.make(customers: allCustomers, projects: allProjects, rules: rules, series: seriesAttrs)

            self.matcher = m
            self.customers = allCustomers
            self.projects = allProjects
            self.units = built
            // Fresh snapshot for this period — clear in-session resolutions & cursor.
            self.resolved = [:]
            self.pathResolved = [:]
            self.cursor = 0
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
    /// An ad-hoc mic session (Slack huddle, impromptu Teams/FaceTime). `seconds`
    /// is the meeting-subtracted ad-hoc duration, matching the Calls tab.
    case call(session: MicSession, seconds: Double)

    var id: String {
        switch self {
        case .signal(let s):       return "sig:\(s.kind):\(s.value)"
        case .hostGroup(let h, _): return "host:\(h.value)"
        case .series(let s):       return "series:\(s.seriesMasterID)"
        case .event(let e):        return "event:\(e.id)"
        case .call(let s, _):      return "call:\(s.id)"
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
        case .call(_, let secs):    return secs
        }
    }

    var title: String {
        switch self {
        case .signal(let s):       return s.value
        case .hostGroup(let h, _): return h.value
        case .series(let s):       return s.sampleSubject
        case .event(let e):        return e.subject.isEmpty ? "(no subject)" : e.subject
        case .call(let s, _):      return Self.callTitle(s)
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
        case .call(let s, _):
            let df = DateFormatter(); df.dateFormat = "EEE d MMM HH:mm"
            let apps = Self.callApps(s)
            let when = df.string(from: s.startedAt)
            return apps.isEmpty ? when : "\(apps.joined(separator: ", ")) · \(when)"
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
        case .call:      return "Call"
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
        case .call:      return "mic.fill"
        }
    }

    /// Confirming this unit writes a reusable rule (vs a one-off attribution).
    /// A call only teaches a rule when it carries a Slack channel.
    var createsRule: Bool {
        switch self {
        case .signal, .hostGroup, .series: return true
        case .event:                       return false
        case .call(let s, _):              return s.slackChannel != nil
        }
    }

    /// Whether "Ignore — don't ask again" applies. Repos can only be skipped.
    var canIgnore: Bool {
        switch self {
        case .signal(let s): return s.kind == .urlHost || s.kind == .appBundleID
        case .hostGroup, .series, .event, .call: return true
        }
    }

    // MARK: Call display helpers

    static func callApps(_ s: MicSession) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for bid in s.voipApps {
            if let label = MicMonitor.displayName(forBundleID: bid), !seen.contains(label) {
                seen.insert(label); out.append(label)
            }
        }
        return out
    }

    static func callTitle(_ s: MicSession) -> String {
        if let p = s.participant, !p.isEmpty { return p }
        if let ch = s.slackChannel, !ch.isEmpty { return "#\(ch)" }
        let apps = callApps(s)
        if !apps.isEmpty { return apps.joined(separator: " / ") }
        return "Microphone activity"
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

/// One path row inside a host group — compact picker + Assign, or a resolved
/// state (assigned/ignored) with an undo when already handled this session.
private struct PathAssignRow: View {
    let path: AppDatabase.SignalAggregate
    var resolvedLabel: String?
    let customers: [Customer]
    let projects: [Project]
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    let onConfirm: (String, String?) -> Void
    let onIgnore: () -> Void
    let onClear: () -> Void

    var pathLabel: String {
        if let slash = path.value.firstIndex(of: "/") { return String(path.value[slash...]) }
        return path.value
    }
    private var timeLabel: String {
        String(format: path.totalSeconds < 3600 ? "%.0f min" : "%.1f h",
               path.totalSeconds < 3600 ? path.totalSeconds / 60 : path.totalSeconds / 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(pathLabel).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(timeLabel).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                if resolvedLabel == nil {
                    Button { onIgnore() } label: { Image(systemName: "eye.slash").font(.system(size: 11)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Ignore this path — don't ask again")
                }
            }
            if let label = resolvedLabel {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(TM.positive)
                    Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", action: onClear).buttonStyle(.borderless).font(.caption)
                }
            } else {
                InlineAssign(
                    customers: customers, projects: projects, confirmLabel: "Assign",
                    onCreateCustomer: onCreateCustomer, onCreateProject: onCreateProject,
                    onConfirm: onConfirm
                )
            }
        }
        .padding(12)
        .background(.quaternary.opacity(resolvedLabel == nil ? 0.4 : 0.25), in: .rect(cornerRadius: 12))
    }
}
