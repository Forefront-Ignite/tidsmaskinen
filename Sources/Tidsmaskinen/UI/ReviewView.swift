import SwiftUI

// ===================================================================
// Review — one list of everything with time in the period, with a
// permanent detail pane. Filter Open / All / Ignored, pick a row, decide:
// Confirm (↵), Skip (H), Ignore (E). J/K move, 1–3 take a suggestion,
// ⌘Z undoes the last decision, / searches, ? lists the shortcuts.
// Attributed rows show their customer and the scope it was written with
// and can be changed in place; ignored rows can be restored. This replaced
// both the one-at-a-time card stack and the separate Discover screen.
// ===================================================================

struct ReviewView: View {
    @EnvironmentObject private var state: AppState

    enum Filter: String, CaseIterable, Identifiable {
        case open, all, ignored
        var id: String { rawValue }
    }

    @State private var rows: [ReviewRow] = []
    @State private var matcher: RuleMatcher = .make(customers: [], projects: [], rules: [])
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var allRules: [Rule] = []
    @State private var filter: Filter = .open
    @State private var customerFilterID: String = ""
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @State private var showShort = false
    @State private var selectedID: String?
    @State private var skipped: Set<String> = []
    @State private var scope: AttributionScope = .always
    @State private var selCustomerID: String = ""
    @State private var selProjectID: String = ""
    @State private var pickerError: String?
    // The rule a Confirm wrote (unit id), so Undo deletes exactly that rule and
    // leaves a permanent rule or another week's assignment for the pattern alone.
    @State private var writtenRules: [String: Rule] = [:]
    @State private var undoStack: [ReviewUnit] = []
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var showShortcuts = false
    @State private var loadError: String?
    @State private var didInitialLoad = false
    @State private var initialLookupTask: Task<Void, Never>?
    @State private var weekStart: Date = Calendar.weekStartingMonday().currentWeekInterval().start
    @State private var selectedDay: Date? = nil    // nil = whole selected week
    /// What an Always rule for the selected signal also clears in the other
    /// weeks of the backlog window — computed off the main thread per selection.
    @State private var impact: (weeks: Int, seconds: Double)?
    @State private var impactTask: Task<Void, Never>?

    private let calendar = Calendar.weekStartingMonday()

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

    /// (validFrom, validTo) for a rule under the current scope, anchored to the
    /// selected day (or the selected week).
    private var scopeBounds: (Date?, Date?) {
        scope.bounds(reference: selectedDay ?? weekStart)
    }

    /// "this week" / "Wed 4 Jun" — used in labels and hints.
    private var periodLabel: String {
        if let day = selectedDay { return DateFormatting.weekdayDayShortMonth.string(from: day) }
        return "this week"
    }

    /// The window a bounded scope covers: the selected day, else the week.
    private var scopeWindowLabel: String {
        scope == .today ? periodLabel : "this week"
    }

    private var isCurrentWeek: Bool { weekStart == calendar.currentWeekInterval().start }

    private var weekTitle: String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(DateFormatting.dayMonth.string(from: weekStart)) – \(DateFormatting.dayMonth.string(from: end))"
    }

    private var weekNumber: Int { calendar.component(.weekOfYear, from: weekStart) }

    // MARK: - Rows

    enum Section: Int, CaseIterable {
        case repos, meetings, calls, appsAndSites
        var title: String {
            switch self {
            case .repos:        return "Git repos"
            case .meetings:     return "Meetings"
            case .calls:        return "Calls"
            case .appsAndSites: return "Apps & sites"
            }
        }
    }

    private func section(of unit: ReviewUnit) -> Section {
        switch unit {
        case .signal(let s):  return s.kind == .gitRepoSlug ? .repos : .appsAndSites
        case .hostGroup:      return .appsAndSites
        case .series, .event: return .meetings
        case .call:           return .calls
        }
    }

    /// Rows after the filter, customer, search and threshold controls, in
    /// section order and largest first.
    private var visibleRows: [ReviewRow] {
        rows.filter { row in
            switch filter {
            case .open:    guard row.isOpen else { return false }
            case .ignored: guard row.status == .ignored else { return false }
            case .all:     break
            }
            if row.belowThreshold && !showShort { return false }
            if !customerFilterID.isEmpty {
                guard case .attributed(let cid, _, _) = row.status, cid == customerFilterID else { return false }
            }
            if !query.isEmpty {
                return row.unit.title.localizedCaseInsensitiveContains(query)
                    || (row.unit.subtitle ?? "").localizedCaseInsensitiveContains(query)
            }
            return true
        }
        .sorted { a, b in
            let sa = section(of: a.unit).rawValue, sb = section(of: b.unit).rawValue
            return sa != sb ? sa < sb : a.totalSeconds > b.totalSeconds
        }
    }

    private var selectedRow: ReviewRow? { rows.first { $0.id == selectedID } }

    private var openRows: [ReviewRow] { rows.filter { $0.isOpen && !$0.belowThreshold } }
    private var openSeconds: Double { openRows.reduce(0) { $0 + $1.totalSeconds } }
    private var attributedSeconds: Double {
        rows.reduce(0) { if case .attributed = $1.status { return $0 + $1.totalSeconds } else { return $0 } }
    }
    private var shortCount: Int { rows.filter { $0.belowThreshold }.count }

    /// Where a decision moves the selection: the next open, unskipped row
    /// after the current one; then the first such row; then — at the end of
    /// the pass — the rows that were skipped.
    private func nextSelection(after id: String?) -> String? {
        let list = visibleRows.filter { $0.isOpen && $0.id != id }
        let idx = visibleRows.firstIndex { $0.id == id } ?? -1
        let after = visibleRows.dropFirst(idx + 1).filter { $0.isOpen && $0.id != id }
        return after.first { !skipped.contains($0.id) }?.id
            ?? list.first { !skipped.contains($0.id) }?.id
            ?? after.first?.id
            ?? list.first?.id
    }

    // MARK: - Lifecycle

    /// If the menu bar or the report asked Review to land on a specific week,
    /// snap to it and clear the request. Returns whether a target was consumed.
    @discardableResult
    private func consumeReviewTarget() -> Bool {
        if let day = state.reviewTargetDay {
            // A single day: its week, then the day chip. Each change reloads.
            state.reviewTargetDay = nil
            state.reviewTargetWeekStart = nil
            initialLookupTask?.cancel()
            let start = calendar.currentWeekInterval(reference: day).start
            let dayStart = calendar.startOfDay(for: day)
            // Set the day first so the week change keeps it (it lies inside
            // the new week); each change reloads, and neither changing does too.
            let changed = start != weekStart || selectedDay != dayStart
            selectedDay = dayStart
            if start != weekStart { weekStart = start }
            if !changed { reload() }
            return true
        }
        guard let target = state.reviewTargetWeekStart else { return false }
        initialLookupTask?.cancel()
        state.reviewTargetWeekStart = nil
        let willTriggerReload = target != weekStart || selectedDay != nil
        selectedDay = nil
        if target != weekStart { weekStart = target }
        if !willTriggerReload { reload() }
        return true
    }

    /// Scan the recent weeks for residual backlog and jump to the oldest one
    /// with open items (falling back to a normal load of the current week).
    private func landOnOldestOpenWeek() {
        let lookupPeriod = period
        initialLookupTask?.cancel()
        initialLookupTask = Task { @MainActor in
            let oldest = (try? await state.currentReviewBacklog())?.oldestOpenWeekStart
            guard !Task.isCancelled, period == lookupPeriod, undoStack.isEmpty, skipped.isEmpty else { return }
            if let oldest, oldest != weekStart {
                weekStart = oldest   // onChange(weekStart) → reload
            } else {
                reload()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .background { ReviewKeyMonitor(handler: handleKey) }
        .onAppear {
            let hadTarget = consumeReviewTarget()
            if !didInitialLoad {
                didInitialLoad = true
                if !hadTarget { landOnOldestOpenWeek() }
            } else if !hadTarget {
                reload()
            }
        }
        .onDisappear { initialLookupTask?.cancel(); toastTask?.cancel(); impactTask?.cancel() }
        .onChange(of: state.reviewTargetWeekStart) { _, _ in _ = consumeReviewTarget() }
        .onChange(of: state.reviewTargetDay) { _, _ in _ = consumeReviewTarget() }
        .onChange(of: weekStart) { _, _ in
            initialLookupTask?.cancel()
            skipped = []
            // A day belongs to its week: keep it when it lies in the new week
            // (a report day chip), clear it when the user navigated away.
            if let day = selectedDay, !week.contains(day) {
                selectedDay = nil          // onChange(selectedDay) reloads
            } else {
                reload()
            }
        }
        .onChange(of: selectedDay) { _, _ in
            initialLookupTask?.cancel()
            skipped = []
            scope = .always   // "This day" is only offered while a day is picked
            reload()
        }
        .onChange(of: selectedID) { _, _ in prepareDetail() }
        .onChange(of: filter) { _, _ in ensureSelection() }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload() }
        .onChange(of: state.commandCenterLastSyncAt) { _, _ in reload() }
        .alert("Database error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    // MARK: - Keyboard

    /// The single-key grammar. `ReviewKeyMonitor` only forwards keys when no
    /// text field is being edited in this window (search, "+ New" and the
    /// picker's search live in text fields or popovers), so typing never
    /// triages. Return is the Confirm button's own default action.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "z": undo(); return true
            default: break
            }
            switch event.keyCode {
            case 123: weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart; return true
            case 124: if !isCurrentWeek { weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart }; return true
            default: return false
            }
        }
        guard flags.isSubset(of: [.shift]) else { return false }
        switch event.characters {
        case "j": moveSelection(by: 1)
        case "k": moveSelection(by: -1)
        case "h": if let r = selectedRow, r.isOpen { skip(r) }
        case "e": if let r = selectedRow { toggleIgnore(r) }
        case "1": takeSuggestion(0)
        case "2": takeSuggestion(1)
        case "3": takeSuggestion(2)
        case "/": searchFocused = true
        case "?": showShortcuts.toggle()
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        let list = visibleRows
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(idx + delta, 0), list.count - 1)
        selectedID = list[next].id
    }

    /// Keep the selection on a visible row; prefer the first open one.
    private func ensureSelection() {
        let list = visibleRows
        if let id = selectedID, list.contains(where: { $0.id == id }) { return }
        selectedID = list.first { $0.isOpen }?.id ?? list.first?.id
    }

    /// After a write: the row we aimed for if it is still listed, else a
    /// sensible visible row (never nothing while the list has rows).
    private func settleSelection(on preferred: String?) {
        if let preferred, visibleRows.contains(where: { $0.id == preferred }) {
            selectedID = preferred
        } else {
            selectedID = nil
            ensureSelection()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review").font(.system(size: 24, weight: .bold))
                    Text("Week \(weekNumber) · \(weekTitle) · \(openRows.count) open · \(formatHours(openSeconds))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .focused($searchFocused)
                        .onSubmit { searchFocused = false }
                    Button {
                        showShortcuts.toggle()
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .help("Keyboard shortcuts (?)")
                    .popover(isPresented: $showShortcuts) { shortcutsHelp }
                    DateNavigator(
                        title: isCurrentWeek ? "This week" : weekTitle,
                        nowLabel: "This week",
                        prevHelp: "Previous week (⌘←)", nextHelp: "Next week (⌘→)",
                        titleMinWidth: 150,
                        nextDisabled: weekStart >= calendar.currentWeekInterval().start,
                        nowDisabled: isCurrentWeek,
                        onPrev: { weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart },
                        onNext: { weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart },
                        onNow: { weekStart = calendar.currentWeekInterval().start }
                    )
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    Text("Open · \(openRows.count)").tag(Filter.open)
                    Text("All").tag(Filter.all)
                    Text("Ignored").tag(Filter.ignored)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Picker("", selection: $customerFilterID) {
                    Text("All customers").tag("")
                    ForEach(customers) { c in Text(c.name).tag(c.id) }
                }
                .labelsHidden().frame(width: 180)
                if shortCount > 0 {
                    Toggle(isOn: $showShort) {
                        Text("Show \(shortCount) under \(AppSettings.reviewMinMinutes) min")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
            }
            dayChips
            progressRow
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    /// "Whole week" + the 7 weekdays of the selected week. Picking a day narrows
    /// the review (and "This day" becomes an offered scope).
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
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(active ? TM.accent : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var progressRow: some View {
        let total = attributedSeconds + openSeconds
        let frac = total > 0 ? attributedSeconds / total : 1
        VStack(spacing: 6) {
            HStack {
                Text("\(formatHours(attributedSeconds)) of \(formatHours(total)) attributed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Rules read at each item's own dates")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(LinearGradient(colors: [TM.accent, Color(hex: "#7a74ff") ?? TM.accent],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 6)
        }
    }

    private var shortcutsHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts").font(.headline)
            ForEach([("↵", "Confirm"), ("H", "Skip — back at the end of the pass"), ("E", "Ignore / restore"),
                     ("J / K", "Next / previous item"), ("1 – 3", "Take a suggestion"), ("⌘Z", "Undo the last decision"),
                     ("/", "Search"), ("⌘← / ⌘→", "Previous / next week"), ("?", "This list")], id: \.0) { k, v in
                HStack(spacing: 10) {
                    Text(k).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 64, alignment: .leading)
                    Text(v).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView("Nothing recorded for \(periodLabel)", systemImage: "clock.arrow.circlepath",
                                   description: Text("Apps, sites, repos, meetings and calls show up here as you work."))
        } else {
            HStack(spacing: 0) {
                list
                    .frame(width: 380)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        let visible = visibleRows
        if visible.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                if filter == .open && query.isEmpty && customerFilterID.isEmpty {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(TM.positive)
                    Text("You're all caught up").font(.headline)
                    Text("Every item for \(periodLabel) has a home.").font(.caption).foregroundStyle(.secondary)
                    Button("See the report") { state.selectedSection = .weeklyReport }
                } else {
                    Text("No items match").font(.headline)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selectedID) {
                ForEach(Section.allCases, id: \.rawValue) { sec in
                    let items = visible.filter { section(of: $0.unit) == sec }
                    if !items.isEmpty {
                        SwiftUI.Section {
                            ForEach(items) { row in
                                listRow(row).tag(row.id)
                            }
                        } header: {
                            Text("\(sec.title) · \(items.count)")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .padding(.leading, 8).padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private func listRow(_ row: ReviewRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.unit.systemImage)
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.unit.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text(rowSubtitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            statusChip(row)
        }
        .padding(.vertical, 3)
        .opacity(skipped.contains(row.id) ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.unit.title), \(rowSubtitle(row)), \(statusText(row))")
    }

    private func rowSubtitle(_ row: ReviewRow) -> String {
        switch row.unit {
        case .signal, .hostGroup:
            return "\(formatHours(row.totalSeconds)) · \(daysLabel(row.perDay))"
        case .series(let s):
            return "Series · \(s.occurrenceCount)× · \(formatHours(row.totalSeconds))"
        case .event, .call:
            return "\(row.unit.subtitle ?? "") · \(formatHours(row.totalSeconds))"
        }
    }

    /// "Tue, Thu, Fri" / "every weekday" / "Mon 4 Jun" from a per-day split.
    private func daysLabel(_ perDay: [Double]) -> String {
        guard selectedDay == nil, perDay.count == 7 else { return periodLabel }
        let days = calendar.days(in: week)
        let active = perDay.enumerated().filter { $0.element > 0 }.map { $0.offset }
        if active.count == 5, active == [0, 1, 2, 3, 4] { return "every weekday" }
        return active.map { DateFormatting.weekdayShort.string(from: days[$0]) }.joined(separator: ", ")
    }

    private func statusText(_ row: ReviewRow) -> String {
        switch row.status {
        case .open: return "Open"
        case .ignored: return "Ignored"
        case .ambient: return "Unattributed"
        case .attributed(let cid, let pid, _): return attrLabel(cid, pid)
        }
    }

    @ViewBuilder
    private func statusChip(_ row: ReviewRow) -> some View {
        switch row.status {
        case .open:
            Text("Open").font(.system(size: 11, weight: .semibold)).foregroundStyle(TM.accent)
                .padding(.horizontal, 7).padding(.vertical, 2).background(TM.accent.opacity(0.12), in: Capsule())
        case .ignored:
            Text("Ignored").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        case .ambient:
            Text("Unattributed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        case .attributed(let cid, let pid, _):
            HStack(spacing: 4) {
                Circle().fill(color(cid, pid)).frame(width: 7, height: 7)
                Text(customers.first { $0.id == cid }?.name ?? cid)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func color(_ cid: String, _ pid: String?) -> Color {
        let p = pid.flatMap { id in projects.first { $0.id == id } }
        let c = customers.first { $0.id == cid }
        return Color(hex: p?.displayColor ?? c?.displayColor) ?? .blue
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let row = selectedRow {
            ScrollView {
                detail(row)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    HStack(spacing: 10) {
                        Text(toast).font(.system(size: 12, weight: .semibold))
                        if !undoStack.isEmpty {
                            Button("Undo ⌘Z") { undo() }.buttonStyle(.borderless).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassCard(radius: 12)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("Pick an item").font(.headline)
                Text("J and K move through the list.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func detail(_ row: ReviewRow) -> some View {
        let unit = row.unit
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: unit.systemImage)
                    .font(.system(size: 20)).foregroundStyle(.secondary)
                    .frame(width: 46, height: 46)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 13))
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
                    Text(formatHours(row.totalSeconds))
                        .font(.system(size: 20, weight: .bold)).monospacedDigit()
                    Text(unit.isHostGroup ? "\(unit.hostPaths.count) to sort" : periodLabel)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            }

            if selectedDay == nil, row.perDay.count == 7 { dayStrip(row.perDay) }

            statusBanner(row)
            detailPanel(for: unit)
            if !row.evidence.isEmpty { evidenceCard(row) }

            if row.status == .ignored {
                HStack(spacing: 6) {
                    Button("Restore") { toggleIgnore(row) }.buttonStyle(.borderedProminent)
                    keycap("E")
                    Spacer()
                }
            } else if unit.isHostGroup, case .hostGroup(let host, _) = unit {
                hostGroupBody(row, host: host)
            } else {
                decisionForm(row)
            }

            Text(row.status == .ignored
                 ? "E restore · J K move · ⌘Z undo · ? all shortcuts"
                 : unit.isHostGroup ? "H skip · E ignore host · J K move · ⌘Z undo · ? all shortcuts"
                 : (row.isOpen ? "↵ confirm · H skip · E ignore · J K move · 1–3 suggestion · ⌘Z undo · ? all shortcuts"
                               : "↵ confirm · E ignore · J K move · ⌘Z undo · ? all shortcuts"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .glassCard(radius: 22)
    }

    /// A small keycap next to an action, so the shortcut reads as a key.
    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Hours per weekday for the selected week.
    @ViewBuilder
    private func dayStrip(_ perDay: [Double]) -> some View {
        let days = calendar.days(in: week)
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 3) {
                    Text(perDay[i] > 0 ? formatHours(perDay[i]) : "–")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(perDay[i] > 0 ? Color.primary : Color.secondary)
                    Text(DateFormatting.weekdayShort.string(from: days[i]))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(perDay[i] > 0 ? TM.accent.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func statusBanner(_ row: ReviewRow) -> some View {
        switch row.status {
        case .open:
            EmptyView()
        case .ambient:
            banner("info.circle", .secondary, "App-only time — not counted as open.",
                   "An editor or browser can't be pinned to one customer, so this never nags. Assign it to teach an app rule for time without a repo or site.")
        case .ignored:
            banner("eye.slash.fill", .gray, "Ignored.", "Hidden from Review, My day and the weekly report. Restore to bring it back.")
        case .attributed(let cid, let pid, let scopeLabel):
            banner("checkmark.seal.fill", .green, "Attributed to \(attrLabel(cid, pid)) · \(scopeLabel).",
                   scopeLabel == "Mixed"
                       ? "Different parts of \(periodLabel) went to different customers; this is the largest share. Confirming below writes a new rule for the whole period."
                       : "Pick something else below to change it — the scope you choose decides how far the change reaches.")
        }
    }

    private func banner(_ systemImage: String, _ tint: Color, _ primary: String, _ secondary: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.caption).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.caption.bold())
                Text(secondary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Picker, scope, note and the Confirm / Skip / Ignore row.
    @ViewBuilder
    private func decisionForm(_ row: ReviewRow) -> some View {
        let unit = row.unit
        let sugg = suggestions(for: unit)
        VStack(alignment: .leading, spacing: 12) {
            if !sugg.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SUGGESTED · PRESS THE NUMBER").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        ForEach(Array(sugg.enumerated()), id: \.offset) { i, s in
                            Button {
                                selCustomerID = s.customerID; selProjectID = s.projectID ?? ""
                            } label: {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Circle().fill(color(s.customerID, s.projectID)).frame(width: 7, height: 7)
                                    Text(attrLabel(s.customerID, s.projectID)).font(.system(size: 12, weight: .semibold))
                                    if let why = s.why { Text(why).font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            AttributionPickerSection(
                customers: customers, projects: projects,
                selectedCustomerID: $selCustomerID, selectedProjectID: $selProjectID,
                onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                showsLabel: false, error: $pickerError
            )
            if let options = scopeOptions(for: unit) {
                AttributionScopePicker(scope: $scope, options: options)
            }
            Text(decisionNote(for: unit)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if row.isOpen {
                    Button("Skip") { skip(row) }
                    keycap("H")
                }
                if unit.canIgnore {
                    Button("Ignore") { toggleIgnore(row) }.padding(.leading, row.isOpen ? 8 : 0)
                    keycap("E")
                }
                Spacer()
                confirmButton(row)
                keycap("↵")
            }
        }
    }

    /// Prominent once a target is picked; plainly bordered (and inert) before,
    /// so nothing is armed by default and the label stays legible.
    @ViewBuilder
    private func confirmButton(_ row: ReviewRow) -> some View {
        let title = scopeOptions(for: row.unit) == nil ? "Confirm" : "Confirm · \(scope.label)"
        if selCustomerID.isEmpty {
            Button(title) {}.buttonStyle(.bordered).disabled(true)
        } else {
            Button(title) { confirm(row) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    /// Scope choices for a unit, or nil when the decision has no scope (a
    /// single meeting is attributed on its own).
    private func scopeOptions(for unit: ReviewUnit) -> [AttributionScope]? {
        var options: [AttributionScope] = [.always, .thisWeek]
        if selectedDay != nil { options.append(.today) }
        switch unit {
        case .event: return nil
        case .call(let s, _): return s.learnableRule == nil ? nil : options + [.justThis]
        case .signal, .hostGroup, .series: return options
        }
    }

    private func decisionNote(for unit: ReviewUnit) -> String {
        let undo = " Undoable with ⌘Z."
        switch unit {
        case .signal(let s):
            let what = "\(unit.kindLabel.lowercased()) · \(s.value)"
            let existing = existingRuleNote(kind: ruleKind(s.kind), pattern: s.kind == .urlPath ? s.value + "*" : s.value)
            if s.kind == .appBundleID {
                return (scope == .always ? "Writes a permanent app rule for \(what): foreground time in this app without a repo or site attributes here."
                        : "Attributes \(what) for \(scopeWindowLabel) only.") + impactNote + existing + undo
            }
            return (scope == .always ? "Writes a permanent rule for \(what)." : "Attributes \(what) for \(scopeWindowLabel) only; other periods can go elsewhere.") + impactNote + existing + undo
        case .hostGroup:
            return ""   // host groups render `hostGroupBody`, which carries its own caption
        case .series:
            return (scope == .always ? "Applies to every occurrence of the series, past and future." : "Overrides only the occurrences in \(scopeWindowLabel); the series itself stays as it is.") + undo
        case .event:
            return "Attributes just this meeting." + undo
        case .call(let s, _):
            guard let what = s.learnableRuleLabel else { return "Pins just this call — no rule is created." + undo }
            return (scope == .justThis ? "Pins just this call — no rule is created."
                    : "Pins this call and teaches a rule for \(what)\(scope == .always ? "" : " for \(scopeWindowLabel)").") + undo
        }
    }

    /// " Also clears 2.1 h open in 3 other weeks." — only for Always, which is
    /// the scope that reaches beyond the period on screen.
    private var impactNote: String {
        guard scope == .always, let impact, impact.seconds > 0 else { return "" }
        return " Also clears \(formatHours(impact.seconds)) open in \(impact.weeks) other week\(impact.weeks == 1 ? "" : "s")."
    }

    /// Names the rule already written for this pattern by another customer, so
    /// Confirm never silently overrides it. Same scope replaces; a narrower
    /// window wins where they overlap (the matcher's specificity order).
    private func existingRuleNote(kind: Rule.Kind, pattern: String) -> String {
        let others = rulesTouchingPeriod.filter { $0.kind == kind && $0.pattern == pattern && $0.customerID != selCustomerID }
        guard let r = others.sorted(by: { $0.createdAt > $1.createdAt }).first else { return "" }
        return " Already ruled → \(attrLabel(r.customerID, r.projectID)) · \(ReviewQueue.scopeLabel(r)); the same scope replaces it, a narrower one wins where they overlap."
    }

    /// Hosts that serve several customers, where a whole-host rule sends every
    /// project to one place. Paths are the right unit there.
    private static let sharedHosts = ["localhost", "127.0.0.1", "portal.azure.com", "*.cloud.microsoft", "*.microsoft.com",
                                      "*.office.com", "*.sharepoint.com", "github.com", "gitlab.com", "bitbucket.org", "*.atlassian.net"]

    /// Permanent rules plus the bounded ones whose window overlaps the period on
    /// screen — an expired day rule from months ago is history, not a conflict.
    private var rulesTouchingPeriod: [Rule] {
        allRules.filter { !$0.isTemporary || (($0.validFrom ?? .distantPast) < period.end && ($0.validTo ?? .distantFuture) > period.start) }
    }

    private func sharedHostWarning(_ host: String) -> String? {
        if let r = rulesTouchingPeriod.first(where: { $0.kind == .urlHost && $0.pattern == host }) {
            return "\(host) is already assigned to \(attrLabel(r.customerID, r.projectID)) (\(ReviewQueue.scopeLabel(r).lowercased())). Assign the paths below instead if this host serves more than one customer."
        }
        if Self.sharedHosts.contains(where: { RuleMatcher.globMatch(pattern: $0, value: host) }) {
            return "\(host) is shared across customers — a whole-host rule would send every project here. Assign the paths below instead."
        }
        return nil
    }

    /// The longest stretches of the signal: when, how long, and what was on
    /// screen. Each opens that day in My day.
    private static let stretchStart: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"; return f }()
    private static let stretchEnd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private func stretchLabel(_ e: ReviewEvidence) -> String {
        "\(Self.stretchStart.string(from: e.start))–\(Self.stretchEnd.string(from: e.end))"
    }

    /// "+ 15 min in 9 shorter stretches" — what the three shown leave out, so
    /// the card adds up to the header.
    private func stretchRemainder(_ row: ReviewRow) -> String? {
        let more = row.stretchCount - row.evidence.count
        let rest = row.perDay.reduce(0, +) - row.evidence.reduce(0) { $0 + $1.seconds }
        guard more > 0, rest >= 30 else { return nil }
        return "+ \(formatHours(rest)) in \(more) shorter stretch\(more == 1 ? "" : "es")"
    }

    private func evidenceCard(_ row: ReviewRow) -> some View {
        detailCard {
            Text("LONGEST STRETCHES").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            ForEach(row.evidence) { e in
                Button {
                    state.timelineTargetDay = e.start
                    state.selectedSection = .timeline
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(stretchLabel(e))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text(formatHours(e.seconds)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        if let d = e.detail, !d.isEmpty {
                            Text(d).font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this day in My day")
                .accessibilityLabel("Open \(stretchLabel(e)) in My day")
            }
            if let rest = stretchRemainder(row) {
                Text(rest).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// Up to three targets: earlier answers for the same signal first, then the
    /// most recently used customers.
    private struct Suggestion { let customerID: String; let projectID: String?; let why: String? }
    private func suggestions(for unit: ReviewUnit) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen = Set<String>()
        func add(_ cid: String, _ pid: String?, _ why: String?) {
            let key = "\(cid)/\(pid ?? "")"
            guard out.count < 3, seen.insert(key).inserted, customers.contains(where: { $0.id == cid }) else { return }
            out.append(Suggestion(customerID: cid, projectID: pid, why: why))
        }
        var pattern: (Rule.Kind, String)?
        switch unit {
        case .signal(let s):        pattern = (ruleKind(s.kind), s.kind == .urlPath ? s.value + "*" : s.value)
        case .hostGroup(let h, _):  pattern = (.urlHost, h.value)
        case .call(let s, _):       pattern = s.learnableRule.map { ($0.kind, $0.pattern) }
        case .series, .event:       pattern = nil
        }
        if let (kind, value) = pattern {
            for r in allRules.filter({ $0.kind == kind && $0.pattern == value }).sorted(by: { $0.createdAt > $1.createdAt }) {
                add(r.customerID, r.projectID, "earlier")
            }
        }
        for r in allRules.sorted(by: { $0.createdAt > $1.createdAt }) { add(r.customerID, r.projectID, nil) }
        return out
    }

    private func takeSuggestion(_ i: Int) {
        guard let row = selectedRow, row.status != .ignored else { return }
        let s = suggestions(for: row.unit)
        guard i < s.count else { return }
        selCustomerID = s[i].customerID
        selProjectID = s[i].projectID ?? ""
    }

    /// Reset the form for the newly selected row: scope back to Always, the
    /// picker prefilled with the current attribution.
    private func prepareDetail() {
        scope = .always
        pickerError = nil
        if case .attributed(let cid, let pid, _)? = selectedRow?.status {
            selCustomerID = cid; selProjectID = pid ?? ""
        } else {
            selCustomerID = ""; selProjectID = ""
        }
        loadImpact()
    }

    /// Open time for the selected signal in the other weeks of the backlog
    /// window (`ReviewQueue.defaultBacklogWeeksBack`), so the Always note can
    /// say what else the rule clears. Resolves those weeks off the main thread;
    /// a whole host counts under both its group id and its plain signal id.
    private func loadImpact() {
        impactTask?.cancel()
        impact = nil
        guard let row = selectedRow, row.isOpen else { return }
        let ids: Set<String>
        switch row.unit {
        case .signal(let s):         ids = s.kind == .urlHost ? [row.id, "host:\(s.value)"] : [row.id]
        case .hostGroup(let h, _):   ids = [row.id, "sig:urlHost:\(h.value)"]
        case .series, .event, .call: return
        }
        let db = state.database, cal = calendar, viewed = weekStart
        let currentStart = cal.currentWeekInterval().start
        let interval = AppSettings.sampleIntervalSeconds
        let idle = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
        let minMinutes = AppSettings.reviewMinMinutes
        impactTask = Task {
            // Debounced: J/K runs through rows faster than four weeks resolve.
            // The worker is detached, so cancellation is forwarded by hand and
            // checked between weeks.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { () -> (weeks: Int, seconds: Double) in
                var weeks = 0, seconds = 0.0
                for w in 0...ReviewQueue.defaultBacklogWeeksBack where !Task.isCancelled {
                    guard let start = cal.date(byAdding: .day, value: -7 * w, to: currentStart), start != viewed,
                          let end = cal.date(byAdding: .day, value: 7, to: start),
                          let rows = try? ReviewQueue.rows(database: db, interval: DateInterval(start: start, end: end),
                                                           sampleIntervalSeconds: interval, idleThresholdSeconds: idle,
                                                           minMinutes: minMinutes) else { continue }
                    let open = rows.filter { ids.contains($0.id) && $0.isOpen }.reduce(0) { $0 + $1.totalSeconds }
                    if open > 0 { weeks += 1; seconds += open }
                }
                return (weeks, seconds)
            }
            let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            impact = found
        }
    }

    @ViewBuilder
    private func hostGroupBody(_ row: ReviewRow, host: AppDatabase.SignalAggregate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AttributionScopePicker(scope: $scope, options: scopeOptions(for: row.unit) ?? [.always])
            VStack(alignment: .leading, spacing: 6) {
                Text("ASSIGN ENTIRE HOST").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                InlineAssign(
                    customers: customers, projects: projects, confirmLabel: "Assign host · \(scope.label)",
                    onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                    onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                    onConfirm: { cust, proj in assignSignal(row.unit, host, customerID: cust, projectID: proj) }
                )
                if let warning = sharedHostWarning(host.value) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text((scope == .always
                          ? "All current and future paths under \(host.value) attribute here."
                          : "Paths under \(host.value) during \(scopeWindowLabel) attribute here.") + impactNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("OR ASSIGN INDIVIDUAL PATHS").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                ForEach(row.unit.hostPaths) { path in
                    PathAssignRow(
                        path: path,
                        customers: customers,
                        projects: projects,
                        onCreateCustomer: { try state.database.createLocalCustomer(name: $0) },
                        onCreateProject: { try state.database.createLocalProject(customerID: $0, name: $1) },
                        onConfirm: { cust, proj in assignSignal(.signal(path), path, customerID: cust, projectID: proj, stay: true) },
                        onIgnore: { ignorePath(path) }
                    )
                }
            }
            HStack(spacing: 6) {
                Button("Skip") { skip(row) }
                keycap("H")
                Button("Ignore host") { toggleIgnore(row) }.padding(.leading, 8)
                keycap("E")
                Spacer()
            }
        }
    }

    // MARK: - Detail panel (meetings & calls)

    /// Extra context under the header so meetings and calls aren't a bare
    /// subject + time — attendee domains and organizer in particular are the
    /// strongest hints for which customer a meeting belongs to.
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
            detailRow("repeat", "\(s.occurrenceCount) occurrence\(s.occurrenceCount == 1 ? "" : "s") \(selectedDay == nil ? "this week" : "this day")")
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
            if let p = s.participant, !p.isEmpty { detailRow("person.crop.circle", "1:1 with \(p) — Always teaches a rule for calls with them") }
            if let ch = s.slackChannel, !ch.isEmpty {
                detailRow("number", "Huddle in #\(ch)")
            } else if s.participant == nil {
                detailRow("info.circle", "Ad-hoc call — assigns just this session. No channel or participant was captured, so there is nothing to learn a rule from.")
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
        case "accepted":            return "Accepted"
        case "tentativelyAccepted": return "Tentatively accepted"
        case "organizer":           return "You organize this meeting"
        case "notResponded":        return "No response yet"
        default:                    return nil
        }
    }

    // MARK: - Actions

    private func attrLabel(_ customerID: String, _ projectID: String?) -> String {
        let c = customers.first { $0.id == customerID }?.name ?? customerID
        if let pid = projectID, let p = projects.first(where: { $0.id == pid })?.name { return "\(c) · \(p)" }
        return c
    }

    private func confirm(_ row: ReviewRow) {
        guard !selCustomerID.isEmpty else { return }
        let cid = selCustomerID, pid = selProjectID.isEmpty ? nil : selProjectID
        let unit = row.unit
        let scopeText = scopeOptions(for: unit) == nil ? "" : " · \(scope.label)"
        let ok: Bool
        switch unit {
        case .signal(let s):
            ok = run { writtenRules[unit.id] = try writeSignalRule(s, customerID: cid, projectID: pid) }
        case .hostGroup(let host, _):
            ok = run { writtenRules[unit.id] = try writeSignalRule(host, customerID: cid, projectID: pid) }
        case .series(let s):
            ok = run { try writeSeries(s, customerID: cid, projectID: pid) }
        case .event(let e):
            ok = run { try state.database.setCalendarEventAttribution(eventID: e.id, customerID: cid, projectID: pid) }
        case .call(let session, _):
            // Pin the session; a channel huddle or a 1:1 call also teaches a
            // channel / participant rule under Always / This week / This day. One
            // transaction: a failed rule insert never leaves the session pinned on its own.
            var rule: Rule?
            if scope.createsRule, let learn = session.learnableRule {
                let (validFrom, validTo) = scopeBounds
                rule = Rule(id: UUID().uuidString, customerID: cid, projectID: pid,
                            kind: learn.kind, pattern: learn.pattern, priority: 100, createdAt: Date(),
                            validFrom: validFrom, validTo: validTo)
            }
            ok = run { try state.database.setMicSessionAttribution(id: session.id, customerID: cid, projectID: pid, rule: rule) }
            if ok { writtenRules[unit.id] = rule }
        }
        if ok { finish(unit, "\(unit.title) → \(attrLabel(cid, pid))\(scopeText)") }
    }

    /// Whole-host or single-path rule from the host group; `stay` keeps the
    /// host selected so the remaining paths can be sorted one by one.
    private func assignSignal(_ unit: ReviewUnit, _ signal: AppDatabase.SignalAggregate,
                              customerID: String, projectID: String?, stay: Bool = false) {
        if run({ writtenRules[unit.id] = try writeSignalRule(signal, customerID: customerID, projectID: projectID) }) {
            undoStack.append(unit)
            showToast("\(signal.value) → \(attrLabel(customerID, projectID)) · \(scope.label)")
            let next = stay ? selectedID : nextSelection(after: selectedID)
            reload()
            settleSelection(on: next)
        }
    }

    private func ignorePath(_ path: AppDatabase.SignalAggregate) {
        if run({ try state.database.hideSignal(kind: .urlPath, value: path.value) }) {
            undoStack.append(.signal(path))
            showToast("Ignored \(path.value)")
            let keep = selectedID
            reload()
            settleSelection(on: keep)
        }
    }

    /// A bounded scope overrides just the occurrences in the window (per-event
    /// overrides win over the series rule); Always attributes the series.
    private func writeSeries(_ s: AppDatabase.MeetingSeriesAggregate, customerID: String, projectID: String?) throws {
        let (from, to) = scopeBounds
        if scope != .always, let from, let to {
            let occurrences = try state.database.calendarEvents(in: DateInterval(start: from, end: to))
                .filter { $0.seriesMasterID == s.seriesMasterID }
            try state.database.setCalendarEventAttribution(eventIDs: occurrences.map(\.id), customerID: customerID, projectID: projectID)
        } else {
            try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: customerID, projectID: projectID, isIgnored: false)
        }
    }

    private func skip(_ row: ReviewRow) {
        skipped.insert(row.id)
        let next = nextSelection(after: row.id)
        selectedID = next
        if next == nil || skipped.contains(next!) { showToast("End of the pass — back at the skipped items") }
    }

    /// Ignore an open row, or restore an ignored one.
    private func toggleIgnore(_ row: ReviewRow) {
        let unit = row.unit
        if row.status == .ignored {
            if run({ try restore(unit) }) {
                showToast("Restored \(unit.title)")
                reload()
                settleSelection(on: row.id)
            }
            return
        }
        guard unit.canIgnore else { return }
        let ok: Bool
        switch unit {
        case .signal(let s):
            if let hk = hiddenKind(s.kind) { ok = run { try state.database.hideSignal(kind: hk, value: s.value) } } else { ok = false }
        case .hostGroup(let host, _):
            ok = run { try state.database.hideSignal(kind: .urlHost, value: host.value) }
        case .series(let s):
            ok = run { try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: nil, projectID: nil, isIgnored: true) }
        case .event(let e):
            ok = run { try state.database.setCalendarEventIgnored(eventID: e.id, isIgnored: true) }
        case .call(let session, _):
            ok = run { try state.database.setMicSessionIgnored(id: session.id, isIgnored: true) }
        }
        if ok { finish(unit, "Ignored \(unit.title)") }
    }

    /// Record the decision, refresh, and move on.
    private func finish(_ unit: ReviewUnit, _ message: String) {
        undoStack.append(unit)
        showToast(message)
        let next = nextSelection(after: unit.id)
        reload()
        settleSelection(on: next)
    }

    private func undo() {
        guard let unit = undoStack.popLast() else { return }
        if run({ try restore(unit) }) {
            showToast("Undid \(unit.title)")
            reload()
            settleSelection(on: unit.id)
        }
    }

    /// Take a decision back: delete the rule this session wrote (only that
    /// one), un-hide, or clear the attribution / ignore flag.
    private func restore(_ unit: ReviewUnit) throws {
        switch unit {
        case .signal(let s):
            if let rule = writtenRules[unit.id] {
                try state.database.deleteRule(id: rule.id)
            } else if let hk = hiddenKind(s.kind) ?? (s.kind == .urlPath ? .urlPath : nil) {
                for h in try state.database.allHiddenSignals() where h.matches(kind: hk, value: s.value) {
                    try state.database.unhide(id: h.id)
                }
            }
        case .hostGroup(let host, _):
            if let rule = writtenRules[unit.id] {
                try state.database.deleteRule(id: rule.id)
            } else {
                for h in try state.database.allHiddenSignals() where h.kind == .urlHost && h.value == host.value {
                    try state.database.unhide(id: h.id)
                }
            }
        case .series(let s):
            try state.database.setMeetingSeriesAttribution(seriesID: s.seriesMasterID, customerID: nil, projectID: nil, isIgnored: false)
            // A bounded confirm wrote per-event overrides; clear them in the period.
            let occurrences = try state.database.calendarEvents(in: period).filter { $0.seriesMasterID == s.seriesMasterID }
            try state.database.setCalendarEventAttribution(eventIDs: occurrences.map(\.id), customerID: nil, projectID: nil)
        case .event(let e):
            try state.database.setCalendarEventAttribution(eventID: e.id, customerID: nil, projectID: nil)
            try state.database.setCalendarEventIgnored(eventID: e.id, isIgnored: false)
        case .call(let session, _):
            try state.database.setMicSessionAttribution(id: session.id, customerID: nil, projectID: nil)
            try state.database.setMicSessionIgnored(id: session.id, isIgnored: false)
            if let rule = writtenRules[unit.id] { try state.database.deleteRule(id: rule.id) }
        }
        writtenRules[unit.id] = nil
    }

    /// Shared rule writer: replace any rule with the same (kind, pattern,
    /// window), then upsert at priority 100 with the current scope's window.
    /// Returns the written rule so Undo can delete exactly it.
    private func writeSignalRule(_ signal: AppDatabase.SignalAggregate, customerID: String, projectID: String?) throws -> Rule {
        let kind = ruleKind(signal.kind)
        let pattern = (signal.kind == .urlPath && !signal.value.contains("*")) ? signal.value + "*" : signal.value
        let (validFrom, validTo) = scopeBounds
        let rule = Rule(
            id: UUID().uuidString, customerID: customerID, projectID: projectID,
            kind: kind, pattern: pattern, priority: 100, createdAt: Date(),
            validFrom: validFrom, validTo: validTo)
        try state.database.upsertReplacingWindow(rule)
        return rule
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation { toast = nil } }
        }
    }

    /// Runs a DB mutation, returning whether it succeeded so callers only
    /// update UI state on success.
    @discardableResult
    private func run(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            state.invalidateReviewBacklog()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    private func hiddenKind(_ k: AppDatabase.SignalAggregate.Kind) -> HiddenSignal.Kind? {
        switch k {
        case .gitRepoSlug: return .gitRepoSlug
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

    // MARK: - Reload

    private func reload() {
        do {
            let built = try ReviewQueue.rows(
                database: state.database,
                interval: period,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds,
                idleThresholdSeconds: TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60),
                minMinutes: AppSettings.reviewMinMinutes
            )
            self.matcher = try RuleMatcher.load(from: state.database)
            self.customers = try state.database.allCustomers()
            self.projects = try state.database.allProjects()
            self.allRules = try state.database.allRules()
            self.rows = built
            ensureSelection()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Key monitor

/// Delivers key presses in Review's window to `handler` while no text field is
/// being edited there (the field editor is then the first responder) — so the
/// single-key grammar works without stealing typing from search, "+ New" or
/// the picker's popover, which is its own key window. Returning true consumes
/// the event.
private struct ReviewKeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ReviewKeyMonitorView {
        let v = ReviewKeyMonitorView()
        v.handler = handler
        return v
    }

    func updateNSView(_ nsView: ReviewKeyMonitorView, context: Context) {
        nsView.handler = handler
    }
}

final class ReviewKeyMonitorView: NSView {
    var handler: ((NSEvent) -> Bool)?
    // Opaque handle from addLocalMonitorForEvents; set on the main actor, read in deinit.
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let win = self.window, event.window === win,
                  !(win.firstResponder is NSTextView) else { return event }
            return (self.handler?(event) ?? false) ? nil : event
        }
    }

    deinit {
        guard let m = monitor else { return }
        if Thread.isMainThread { NSEvent.removeMonitor(m) } else { DispatchQueue.main.async { NSEvent.removeMonitor(m) } }
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
        case .hostGroup(let h, _):  return h.totalSeconds   // the host's open time, not just the paths above the threshold
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
    /// A call only teaches a rule when it carries a Slack channel or a participant.
    var createsRule: Bool {
        switch self {
        case .signal, .hostGroup, .series: return true
        case .event:                       return false
        case .call(let s, _):              return s.learnableRule != nil
        }
    }

    var isRepo: Bool {
        if case .signal(let s) = self { return s.kind == .gitRepoSlug }
        return false
    }

    /// Whether "Ignore — don't ask again" applies.
    var canIgnore: Bool {
        switch self {
        case .signal(let s): return s.kind == .gitRepoSlug || s.kind == .urlHost || s.kind == .appBundleID
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

/// One path row inside a host group — compact picker + Assign. An assigned
/// or ignored path leaves the group on the next reload.
private struct PathAssignRow: View {
    let path: AppDatabase.SignalAggregate
    let customers: [Customer]
    let projects: [Project]
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    let onConfirm: (String, String?) -> Void
    let onIgnore: () -> Void

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
                Button { onIgnore() } label: { Image(systemName: "eye.slash").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Ignore this path — don't ask again")
                    .accessibilityLabel("Ignore path")
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
