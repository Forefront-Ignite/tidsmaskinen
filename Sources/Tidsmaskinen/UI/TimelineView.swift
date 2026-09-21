import SwiftUI
import AppKit

struct TimelineView: View {
    @EnvironmentObject private var state: AppState

    @State private var day: Date = Calendar.current.startOfDay(for: Date())
    @State private var bundle: TimelineBuilder.DayBundle = TimelineBuilder.DayBundle(calendar: [], calls: [], foreground: [], claudeCode: [])
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var selectedBlock: TimelineBlock?
    /// A moment Review asked for (a stretch's start): once the day is loaded,
    /// the block covering it is selected so its popover opens right there.
    @State private var pendingFocus: Date?
    /// The other sessions of an agent agenda group, pinned along with the first.
    @State private var agendaSessionIDs: [String] = []
    @State private var refreshTimer: Timer?
    @State private var nowTimer: Timer?
    @State private var now: Date = Date()
    @State private var loadError: String?
    @State private var zoom: CGFloat = 1.0
    @State private var zoomAtPinchStart: CGFloat?
    @State private var showLegend: Bool = false
    @State private var showHidden: Bool = false
    @State private var hasHiddenSignals: Bool = false
    @State private var hasIgnoredMeetings: Bool = false
    @State private var pendingUndo: PendingUndo?
    @State private var pendingUndoDismiss: Task<Void, Never>?
    @State private var undoError: String?
    /// Block the agenda popover edits (separate from `selectedBlock`, which
    /// drives the Gantt-strip popover, so the two popovers never collide). For
    /// a multi-block group this is a synthesized block spanning the group.
    @State private var agendaBlock: TimelineBlock?
    @State private var agendaGroupID: String?
    /// Derived data cached so it isn't recomputed on every body evaluation
    /// (the view re-renders on 8s/30s timers). Refreshed in `reload()` and when
    /// the Lanes menu changes which tracks are shown.
    @State private var cachedRowHeights: [TimelineBlock.Track: CGFloat] = [:]
    @State private var cachedAgendaGroups: [AgendaGroup] = []
    /// Day stats, the same math as the report's day column (`WeeklyReport`)
    /// and Review's open backlog (`ReviewQueue`).
    @State private var dayActiveSeconds: TimeInterval = 0
    @State private var dayAttributedSeconds: TimeInterval = 0
    @State private var dayOpenSeconds: TimeInterval = 0
    @State private var dayOpenCount: Int = 0
    @State private var dayMeetingSeconds: TimeInterval = 0
    @AppStorage(SettingsKey.timelineHiddenLanes) private var hiddenLanesRaw: String = ""

    /// Combined gate for the "show hidden items" eye toggle. The toggle is
    /// disabled when there's nothing to reveal — neither hidden apps/hosts
    /// (foreground filter) nor ignored meetings on the calendar track.
    private var hasHiddenContent: Bool { hasHiddenSignals || hasIgnoredMeetings }

    /// In-flight undo entry. Kept transient — auto-dismisses after a few seconds.
    struct PendingUndo: Equatable {
        let scope: MeetingIgnoreEvent.Scope
        let subject: String
        /// Stable ID so SwiftUI animates an update when a newer undo replaces an older one.
        let id = UUID()
    }

    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 8.0

    private let labelColumnWidth: CGFloat = 124
    private let rulerHeight: CGFloat = 26
    private let baseRowHeight: CGFloat = 60
    private let activeBlockHeight: CGFloat = 48
    private let compactLaneHeight: CGFloat = 32
    private let lanePadding: CGFloat = 4
    private let idleBarHeight: CGFloat = 8
    private let rowSpacing: CGFloat = 8

    private var hiddenLanes: Set<TimelineBlock.Track> {
        Set(hiddenLanesRaw.split(separator: ",").compactMap { TimelineBlock.Track(rawValue: String($0)) })
    }

    /// Every lane is on by default; the Lanes menu switches lanes off.
    private var allTracks: [TimelineBlock.Track] {
        TimelineBlock.Track.allCases.filter { !hiddenLanes.contains($0) }
    }

    private var dayInterval: DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// X-axis range: focus on 06:00–22:00 by default; expand if blocks fall outside.
    private var visibleRange: (start: Date, end: Date) {
        let cal = Calendar.current
        var visibleStart = cal.date(byAdding: .hour, value: 6, to: dayInterval.start) ?? dayInterval.start
        var visibleEnd = cal.date(byAdding: .hour, value: 22, to: dayInterval.start) ?? dayInterval.end

        let allBlocks = bundle.calendar + bundle.calls + bundle.foreground + bundle.claudeCode
        for b in allBlocks {
            if b.startedAt < visibleStart { visibleStart = b.startedAt }
            if b.endedAt > visibleEnd { visibleEnd = b.endedAt }
        }
        return (visibleStart, visibleEnd)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    dayStats
                    timelineStrip
                        .frame(height: stripHeight)
                    agendaSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .overlay(alignment: .bottom) { undoToast }
        .onChange(of: state.timelineTargetDay) { _, _ in consumeTimelineTarget() }
        .onAppear {
            consumeTimelineTarget()
            reload()
            let t = Timer(timeInterval: 8, repeats: true) { _ in
                Task { @MainActor in reload() }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t

            let n = Timer(timeInterval: 30, repeats: true) { _ in
                Task { @MainActor in now = Date() }
            }
            RunLoop.main.add(n, forMode: .common)
            nowTimer = n
        }
        .onDisappear {
            refreshTimer?.invalidate(); refreshTimer = nil
            nowTimer?.invalidate(); nowTimer = nil
            pendingUndoDismiss?.cancel(); pendingUndoDismiss = nil
        }
        .onChange(of: day) { _, _ in
            reload()
            pendingUndoDismiss?.cancel()
            pendingUndo = nil
            undoError = nil
        }
        .onChange(of: showHidden) { _, _ in reload() }
        .onChange(of: hiddenLanesRaw) { _, _ in recomputeDerived() }
        .onChange(of: pendingUndo) { _, _ in undoError = nil }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload() }
        .onChange(of: state.commandCenterLastSyncAt) { _, _ in reload() }
    }

    /// A report cell asked for a day; a Review stretch asked for a moment in it.
    private func consumeTimelineTarget() {
        guard let target = state.timelineTargetDay else { return }
        state.timelineTargetDay = nil
        let start = Calendar.current.startOfDay(for: target)
        pendingFocus = target > start ? target : nil
        if day == start { reload() } else { day = start }   // onChange(of: day) reloads
    }

    private func focusPendingBlock() {
        guard let at = pendingFocus else { return }
        pendingFocus = nil
        let candidates = bundle.foreground + bundle.calls + bundle.calendar + bundle.claudeCode
        guard let block = candidates.first(where: { !$0.isIdle && $0.startedAt <= at && at < $0.endedAt }) else { return }
        closeAgendaPopover()
        selectedBlock = block
    }

    // MARK: - Day stats

    private static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// One agenda row: every non-idle block of the day that shares a repo,
    /// host, app, meeting or call, so a repo touched five times is one line
    /// with one "Attribute all 5" instead of five buttons.
    struct AgendaGroup: Identifiable {
        let id: String
        let blocks: [TimelineBlock]       // sorted by start
        var first: TimelineBlock { blocks[0] }
        var total: TimeInterval { blocks.reduce(0) { $0 + $1.durationSeconds } }
        var isIgnored: Bool { blocks.allSatisfy(\.isIgnored) }
    }

    /// Reads the cache; recomputed only in `recomputeDerived()`.
    private var agendaGroups: [AgendaGroup] { cachedAgendaGroups }

    private func computeAgendaGroups() -> [AgendaGroup] {
        var groups: [String: [TimelineBlock]] = [:]
        for b in allTracks.flatMap({ blocks(for: $0) }) where !b.isIdle {
            groups[groupKey(b), default: []].append(b)
        }
        return groups.map { AgendaGroup(id: $0.key, blocks: $0.value.sorted { $0.startedAt < $1.startedAt }) }
            .sorted { $0.first.startedAt < $1.first.startedAt }
    }

    private func groupKey(_ b: TimelineBlock) -> String {
        switch b.source {
        case .calendarEvent(let id): return "evt:\(id)"
        case .micSession(let id):    return "call:\(id)"
        case .claudeSession:         return "agent:\(b.ruleSignal?.pattern ?? b.title)"   // the repo, not a folder name two repos can share
        case .foregroundSamples:
            if let sig = b.ruleSignal { return "fg:\(sig.kind.rawValue):\(sig.pattern)" }
            return "fg:\(b.title)"
        }
    }

    /// Cached row height for a track (falls back to a fresh compute before the
    /// first cache fill).
    private func height(for track: TimelineBlock.Track) -> CGFloat {
        cachedRowHeights[track] ?? rowHeight(for: track)
    }

    /// Refill the derived caches from the current `bundle` / track set.
    private func recomputeDerived() {
        var heights: [TimelineBlock.Track: CGFloat] = [:]
        for t in TimelineBlock.Track.allCases { heights[t] = rowHeight(for: t) }
        cachedRowHeights = heights
        cachedAgendaGroups = computeAgendaGroups()
    }

    @ViewBuilder
    private var dayStats: some View {
        HStack(spacing: 28) {
            stat(durationLabel(dayActiveSeconds), "active")
            stat(durationLabel(dayAttributedSeconds), "attributed")
                .help("Hours credited to customers, as the report counts them. Meetings bill their booked length and a call during a meeting bills on top, so this can exceed active time at the keyboard.")
            stat(durationLabel(dayOpenSeconds),
                 dayOpenCount == 0 ? "open" : "open · \(dayOpenCount) item\(dayOpenCount == 1 ? "" : "s")")
            stat(durationLabel(dayMeetingSeconds), "in meetings")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 23, weight: .bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Overview strip (the Gantt, capped height)

    private var stripHeight: CGFloat {
        var h: CGFloat = 8 + rulerHeight + rowSpacing + 12
        for t in allTracks { h += height(for: t) + rowSpacing }
        return h
    }

    @ViewBuilder
    private var timelineStrip: some View {
        GeometryReader { outer in
            let available = max(outer.size.width - labelColumnWidth - 24, 220)
            let contentWidth = available * zoom

            HStack(alignment: .top, spacing: 0) {
                labelColumn
                    .frame(width: labelColumnWidth + 12, alignment: .leading)

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        timeRuler(width: contentWidth)
                            .frame(width: contentWidth, height: rulerHeight)
                        ForEach(allTracks, id: \.self) { track in
                            trackRow(track, blocks: blocks(for: track), width: contentWidth)
                                .frame(width: contentWidth, height: height(for: track))
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                }
                // .never, not .hidden: on macOS .hidden still draws the bar while a mouse is connected.
                .scrollIndicators(.never)
                .background(
                    TimelineScrollZoom { deltaY in
                        let factor = pow(1.01, deltaY)
                        zoom = max(minZoom, min(maxZoom, zoom * factor))
                    }
                )
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = zoomAtPinchStart ?? zoom
                            if zoomAtPinchStart == nil { zoomAtPinchStart = zoom }
                            zoom = max(minZoom, min(maxZoom, base * value.magnification))
                        }
                        .onEnded { _ in zoomAtPinchStart = nil }
                )
            }
            .padding(8)
        }
        .glassCard(radius: 18)
    }

    // MARK: - Agenda (readable list)

    @ViewBuilder
    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agenda · grouped by repo, meeting and call")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            if agendaGroups.isEmpty {
                Text("No activity recorded for this day yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(agendaGroups) { group in
                    agendaGroupRow(group)
                }
            }
        }
    }

    @ViewBuilder
    private func agendaGroupRow(_ group: AgendaGroup) -> some View {
        let block = group.first
        let tint = color(for: block)
        let openCount = group.blocks.filter { $0.attribution.customer == nil }.count
        let attributed = openCount == 0
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(attributed ? 0.18 : 0.10))
                Image(systemName: trackIcon(block.track))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(attributed ? tint : Color.secondary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(groupTitle(group)).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(groupSubtitle(group)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)

            if group.isIgnored {
                Text(ignoredTag(block))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            } else if attributed {
                HStack(spacing: 7) {
                    Circle().fill(tint).frame(width: 10, height: 10)
                    Text(groupAttributionLabel(group))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                }
            } else {
                Text(openCount == group.blocks.count ? "Unattributed" : "\(openCount) of \(group.blocks.count) unattributed")
                    .font(.caption).foregroundStyle(.secondary)
                if let app = appOnlyBundleID(block) {
                    Button("Ignore app") { hideApp(app) }.controlSize(.small)
                }
                Button(group.blocks.count > 1 ? "Attribute all \(group.blocks.count)" : "Attribute") {
                    openAgendaPopover(group)
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassCard(radius: 16)
        .opacity(group.isIgnored ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { openAgendaPopover(group) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(groupTitle(group)), \(groupSubtitle(group)), \(group.isIgnored ? ignoredTag(block) : (attributed ? groupAttributionLabel(group) : "Unattributed"))")
        .accessibilityAction(named: "Open") { openAgendaPopover(group) }
        .popover(isPresented: agendaPopoverBinding(group.id)) {
            ReattributePopover(block: agendaBlock ?? block,
                               customers: customers,
                               projects: projects,
                               state: state,
                               onSaved: { closeAgendaPopover(); reload() },
                               onCancel: { closeAgendaPopover() },
                               onIgnored: { event in closeAgendaPopover(); stageUndo(event) },
                               extraSessionIDs: agendaSessionIDs)
        }
    }

    /// Clear the Gantt-strip selection so the two popovers can never both open.
    /// A multi-block foreground group edits one synthesized block covering
    /// every sample, so "Just this" reaches all of them; an agent group edits
    /// its first session and hands the popover the other session ids so a
    /// pin reaches every session the row claims.
    private func openAgendaPopover(_ group: AgendaGroup) {
        selectedBlock = nil
        agendaBlock = groupBlock(group)
        agendaSessionIDs = group.blocks.dropFirst().compactMap { b in
            if case .claudeSession(let id) = b.source { return id } else { return nil }
        }
        agendaGroupID = group.id
    }

    private func closeAgendaPopover() {
        agendaGroupID = nil
        agendaBlock = nil
        agendaSessionIDs = []
    }

    private func groupBlock(_ group: AgendaGroup) -> TimelineBlock {
        let first = group.first
        guard group.blocks.count > 1, case .foregroundSamples = first.source else { return first }
        let ids = group.blocks.flatMap { b -> [Int64] in
            if case .foregroundSamples(let ids) = b.source { return ids } else { return [] }
        }
        return TimelineBlock(
            id: "group-\(group.id)", track: first.track, source: .foregroundSamples(ids: ids),
            startedAt: first.startedAt, endedAt: group.blocks.last?.endedAt ?? first.endedAt,
            title: groupTitle(group), subtitle: "\(group.blocks.count) stretches",
            attribution: first.attribution, eventAttribution: nil,
            hasManualOverride: group.blocks.contains(where: \.hasManualOverride), isIdle: false,
            appBundleID: first.appBundleID, seriesMasterID: nil,
            ruleSignal: first.ruleSignal, isIgnored: first.isIgnored)
    }

    private func agendaPopoverBinding(_ groupID: String) -> Binding<Bool> {
        Binding(get: { agendaGroupID == groupID },
                set: { if !$0 { closeAgendaPopover() } })
    }

    private func groupTitle(_ group: AgendaGroup) -> String {
        let b = group.first
        if case .foregroundSamples = b.source, let sig = b.ruleSignal, sig.kind != .appBundleID {
            return sig.pattern      // the repo or host the stretches share
        }
        return b.title
    }

    private func groupSubtitle(_ group: AgendaGroup) -> String {
        let f = Self.hhmm
        if group.blocks.count == 1 {
            let b = group.first
            var parts = ["\(f.string(from: b.startedAt))–\(f.string(from: b.endedAt))", durationLabel(b.durationSeconds)]
            if let sub = b.subtitle { parts.append(sub) }
            return parts.joined(separator: " · ")
        }
        let noun: String
        switch group.first.source {
        case .claudeSession:     noun = "sessions"
        case .foregroundSamples: noun = "stretches"
        default:                 noun = "blocks"
        }
        let starts = group.blocks.prefix(3).map { f.string(from: $0.startedAt) }.joined(separator: ", ")
        return "\(group.blocks.count) \(noun) · \(starts)\(group.blocks.count > 3 ? "…" : "") · \(durationLabel(group.total)) total"
    }

    private func groupAttributionLabel(_ group: AgendaGroup) -> String {
        let keys = Set(group.blocks.map { "\($0.attribution.customer?.id ?? "")/\($0.attribution.project?.id ?? "")" })
        if keys.count > 1 { return "Mixed" }
        return agendaAttributionLabel(group.first)
    }

    private func agendaAttributionLabel(_ block: TimelineBlock) -> String {
        guard let c = block.attribution.customer else { return "Unattributed" }
        if let p = block.attribution.project { return "\(c.name) · \(p.name)" }
        return c.name
    }

    private func ignoredTag(_ block: TimelineBlock) -> String {
        switch block.track {
        case .calendar: return "Ignored"
        case .calls:    return "Ignored call"
        default:        return "Ignored repo"
        }
    }

    /// Foreground time with no repo or site: an app rule is the only handle.
    private func appOnlyBundleID(_ block: TimelineBlock) -> String? {
        guard block.track == .foreground, let sig = block.ruleSignal, sig.kind == .appBundleID else { return nil }
        return sig.pattern
    }

    private func hideApp(_ bundleID: String) {
        do {
            try state.database.hideSignal(kind: .appBundleID, value: bundleID)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            // My day keeps "next day" enabled (unlike Review/Calls) so you
            // can look ahead at booked meetings on future days.
            DateNavigator(
                title: dayLabel,
                nowLabel: "Today",
                prevHelp: "Previous day (⌘←)",
                nextHelp: "Next day (⌘→)",
                nowDisabled: isToday,
                prevShortcut: KeyboardShortcut(.leftArrow, modifiers: .command),
                nextShortcut: KeyboardShortcut(.rightArrow, modifiers: .command),
                nowShortcut: KeyboardShortcut("t", modifiers: .command),
                onPrev: { day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day },
                onNext: { day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day },
                onNow: { day = Calendar.current.startOfDay(for: Date()) }
            )
            Spacer()
            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            lanesMenu
            legendButton
            zoomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Which lanes are drawn, plus the hidden/ignored reveal — one labelled
    /// menu in place of two unlabelled icon toggles.
    @ViewBuilder
    private var lanesMenu: some View {
        Menu {
            ForEach(TimelineBlock.Track.allCases, id: \.self) { track in
                Toggle(track.label, isOn: laneBinding(track))
            }
            Divider()
            Toggle("Show hidden apps and hosts, ignored meetings and calls", isOn: $showHidden)
                .disabled(!hasHiddenContent)
        } label: {
            Label("Lanes", systemImage: "rectangle.split.3x1")
        }
        .fixedSize()
        .help("Choose which lanes to show")
    }

    private func laneBinding(_ track: TimelineBlock.Track) -> Binding<Bool> {
        Binding(get: { !hiddenLanes.contains(track) },
                set: { on in
                    var set = hiddenLanes
                    if on { set.remove(track) } else { set.insert(track) }
                    hiddenLanesRaw = set.map(\.rawValue).sorted().joined(separator: ",")
                })
    }

    @ViewBuilder
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                zoom = max(minZoom, zoom / 1.5)
            } label: { Image(systemName: "minus.magnifyingglass") }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= minZoom)
            .help("Zoom out (⌘−)")

            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40)

            Button {
                zoom = min(maxZoom, zoom * 1.5)
            } label: { Image(systemName: "plus.magnifyingglass") }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= maxZoom)
            .help("Zoom in (⌘+)")

            Button("1×") {
                zoom = 1.0
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(zoom == 1.0)
            .help("Reset zoom (⌘0)")
        }
    }

    // MARK: - Legend

    @ViewBuilder
    private var legendButton: some View {
        Button {
            showLegend.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(showLegend ? Color.accentColor : .secondary)
        }
        .help("What the colors and borders mean")
        .accessibilityLabel("Timeline legend")
        .popover(isPresented: $showLegend, arrowEdge: .bottom) {
            legendPopover
        }
    }

    @ViewBuilder
    private var legendPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Legend").font(.headline)
            legendRow(
                blockSwatch(fill: .blue, border: .blue.opacity(0.55)),
                "Attributed block",
                "Filled with the customer or project color."
            )
            legendRow(
                blockSwatch(fill: .blue, border: .white.opacity(0.85), lineWidth: 1.5, pin: true),
                "Manual override",
                "White outline and a pin — you set this block by hand."
            )
            legendRow(
                blockSwatch(fill: .pink.opacity(0.85), border: .orange.opacity(0.7), dash: true),
                "Unmatched session",
                "Dashed orange — no rule matched. Attribute it in Review or by clicking it."
            )
            legendRow(
                blockSwatch(fill: .gray, border: .secondary.opacity(0.7), dash: true, opacity: 0.6),
                "Ignored",
                "Dashed grey and faded — work in an ignored repo, or an ignored meeting or call (shown with the Lanes menu's reveal on). Excluded from the report."
            )
            legendRow(idleSwatch, "Idle", "Thin bar along the bottom — no input during this stretch.")
            legendRow(nowSwatch, "Now", "Red line marks the current time (today only).")
        }
        .padding(16)
        .frame(width: 360)
    }

    private func legendRow(_ swatch: some View, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            swatch.frame(width: 36, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func blockSwatch(fill: Color,
                             border: Color,
                             dash: Bool = false,
                             lineWidth: CGFloat = 0.5,
                             pin: Bool = false,
                             opacity: Double = 1.0) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [fill.opacity(0.95), fill.opacity(0.75)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: lineWidth, dash: dash ? [3, 3] : []))
            )
            .overlay(alignment: .trailing) {
                if pin {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.white)
                        .padding(.trailing, 2)
                }
            }
            .opacity(opacity)
    }

    private var idleSwatch: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 6)
        }
    }

    private var nowSwatch: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 1.5)
        }
    }

    private var dayLabel: String {
        DateFormatting.dayMonthWeekdayYear.string(from: day)
    }

    // MARK: - Label column (sticky)

    @ViewBuilder
    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Align with time ruler height.
            Color.clear.frame(height: rulerHeight)
            ForEach(allTracks, id: \.self) { track in
                trackLabel(track)
                    .frame(height: height(for: track), alignment: .top)
            }
        }
        .padding(.leading, 12)
        .padding(.top, 8)
    }

    // MARK: - Lane assignment (vertical stacking for overlapping blocks)

    /// A block paired with the lane index it should render in.
    private struct LanedBlock: Identifiable {
        let block: TimelineBlock
        let lane: Int
        var id: String { block.id }
    }

    /// Greedy lane assignment: each block goes into the lowest-numbered lane
    /// whose previous block has already ended.
    private func assignLanes(_ blocks: [TimelineBlock]) -> [LanedBlock] {
        let sorted = blocks.sorted { $0.startedAt < $1.startedAt }
        var laneEnds: [Date] = []
        var result: [LanedBlock] = []
        for block in sorted {
            var assigned: Int?
            for i in 0..<laneEnds.count where laneEnds[i] <= block.startedAt {
                assigned = i
                laneEnds[i] = block.endedAt
                break
            }
            if let lane = assigned {
                result.append(LanedBlock(block: block, lane: lane))
            } else {
                result.append(LanedBlock(block: block, lane: laneEnds.count))
                laneEnds.append(block.endedAt)
            }
        }
        return result
    }

    private func laneCount(for track: TimelineBlock.Track) -> Int {
        let active = blocks(for: track).filter { !$0.isIdle }
        return (assignLanes(active).map(\.lane).max() ?? -1) + 1
    }

    /// Per-track row height. Single-lane tracks keep the original 60pt row;
    /// tracks with overlapping blocks grow vertically to fit each lane.
    private func rowHeight(for track: TimelineBlock.Track) -> CGFloat {
        let lanes = laneCount(for: track)
        if lanes <= 1 { return baseRowHeight }
        let stackedHeight = lanePadding
            + CGFloat(lanes) * compactLaneHeight
            + CGFloat(max(0, lanes - 1)) * lanePadding
            + lanePadding
            + idleBarHeight
        return max(baseRowHeight, stackedHeight)
    }

    @ViewBuilder
    private func trackLabel(_ track: TimelineBlock.Track) -> some View {
        let blocks = blocks(for: track)
        let total = totalActiveDuration(blocks)
        let activeCount = blocks.filter { !$0.isIdle }.count
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(trackTint(track).opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: trackIcon(track))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(trackTint(track))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.label)
                    .font(.callout.weight(.semibold))
                if total > 0 {
                    Text(durationLabel(total))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(activeCount) block\(activeCount == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    Text("no activity")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func trackTint(_ track: TimelineBlock.Track) -> Color {
        switch track {
        case .calendar:   return .blue
        case .calls:      return .orange
        case .foreground: return .green
        case .claudeCode: return .pink
        }
    }

    private func trackIcon(_ track: TimelineBlock.Track) -> String {
        switch track {
        case .calendar:   return "calendar"
        case .calls:      return "mic.fill"
        case .foreground: return "macwindow"
        case .claudeCode: return "sparkles"
        }
    }

    private func blocks(for track: TimelineBlock.Track) -> [TimelineBlock] {
        switch track {
        case .calendar:   return bundle.calendar
        case .calls:      return bundle.calls
        case .foreground: return bundle.foreground
        case .claudeCode: return bundle.claudeCode
        }
    }

    private func totalActiveDuration(_ blocks: [TimelineBlock]) -> TimeInterval {
        blocks.reduce(0) { $0 + ($1.isIdle ? 0 : $1.durationSeconds) }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        let h = mins / 60
        let m = mins % 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    // MARK: - Time ruler

    private func timeRuler(width: CGFloat) -> some View {
        let (start, end) = visibleRange
        let totalSeconds = end.timeIntervalSince(start)
        let cal = Calendar.current
        let pxPerHour = totalSeconds > 0 ? width / CGFloat(totalSeconds / 3600) : 0
        let showQuarterTicks = pxPerHour >= 240

        // Anchor at the hour containing `start`.
        let startHour = cal.date(bySetting: .minute, value: 0, of: start).flatMap {
            cal.date(bySetting: .second, value: 0, of: $0)
        } ?? start

        return Canvas { ctx, size in
            var t = startHour
            while t <= end {
                let comps = cal.dateComponents([.hour, .minute], from: t)
                let minute = comps.minute ?? 0
                let hour = (comps.hour ?? 0) % 24

                let elapsed = t.timeIntervalSince(start)
                let x = CGFloat(elapsed / totalSeconds) * size.width
                let inRange = x >= -1 && x <= size.width + 1

                if inRange {
                    let isHour = minute == 0
                    let isHalf = minute == 30
                    let tickH: CGFloat
                    let tickColor: GraphicsContext.Shading
                    if isHour {
                        tickH = 10; tickColor = .color(Color.secondary.opacity(0.55))
                    } else if isHalf {
                        tickH = 6;  tickColor = .color(Color.secondary.opacity(0.30))
                    } else {
                        tickH = 4;  tickColor = .color(Color.secondary.opacity(0.18))
                    }
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height - tickH))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: tickColor, lineWidth: 1)

                    if isHour {
                        let label = Text(String(format: "%02d:00", hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ctx.draw(label, at: CGPoint(x: x + 4, y: size.height - 12), anchor: .leading)
                    }
                }

                t = cal.date(byAdding: .minute, value: showQuarterTicks ? 15 : 30, to: t) ?? end.addingTimeInterval(1)
            }

            // Baseline.
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Color.secondary.opacity(0.25)), lineWidth: 0.5)
        }
    }

    // MARK: - Track row

    @ViewBuilder
    private func trackRow(_ track: TimelineBlock.Track,
                          blocks: [TimelineBlock],
                          width: CGFloat) -> some View {
        let (start, end) = visibleRange
        let totalSeconds = end.timeIntervalSince(start)
        let active = blocks.filter { !$0.isIdle }
        let idle = blocks.filter { $0.isIdle }
        let laned = assignLanes(active)
        let lanes = (laned.map(\.lane).max() ?? -1) + 1
        let rowH = height(for: track)
        let stacked = lanes > 1
        let blockH: CGFloat = stacked ? compactLaneHeight : activeBlockHeight

        ZStack(alignment: .topLeading) {
            // Row background + vertical hour grid lines.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                hourGridLines(width: width, height: rowH)
            }
            .frame(width: width, height: rowH)

            // Idle: thin bar pinned to the bottom of the row.
            ForEach(idle) { block in
                idleBar(block, contentWidth: width, totalSeconds: totalSeconds, start: start, rowH: rowH)
            }

            // Active blocks — vertically centered if a single lane, otherwise stacked.
            ForEach(laned) { laned in
                let y: CGFloat = stacked
                    ? lanePadding + CGFloat(laned.lane) * (compactLaneHeight + lanePadding)
                    : (rowH - activeBlockHeight) / 2
                blockRect(laned.block,
                          contentWidth: width,
                          totalSeconds: totalSeconds,
                          start: start,
                          yPos: y,
                          height: blockH)
            }

            // Now indicator (only on today, only inside visible range).
            if isToday, now >= start, now <= end {
                let x = xPosition(for: now, width: width, start: start, totalSeconds: totalSeconds)
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 1.5, height: rowH)
                    .offset(x: x)
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .offset(x: x - 3, y: -3)
            }
        }
        .frame(width: width, height: rowH)
    }

    @ViewBuilder
    private func hourGridLines(width: CGFloat, height: CGFloat) -> some View {
        let (start, end) = visibleRange
        let totalSeconds = end.timeIntervalSince(start)
        let cal = Calendar.current
        let anchor = cal.date(bySetting: .minute, value: 0, of: start).flatMap {
            cal.date(bySetting: .second, value: 0, of: $0)
        } ?? start

        Canvas { ctx, size in
            var t = anchor
            while t <= end {
                let elapsed = t.timeIntervalSince(start)
                let x = CGFloat(elapsed / totalSeconds) * size.width
                if x >= 0 && x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path,
                               with: .color(Color.secondary.opacity(0.10)),
                               lineWidth: 0.5)
                }
                t = cal.date(byAdding: .hour, value: 1, to: t) ?? end.addingTimeInterval(1)
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func idleBar(_ block: TimelineBlock,
                         contentWidth: CGFloat,
                         totalSeconds: TimeInterval,
                         start: Date,
                         rowH: CGFloat) -> some View {
        let x = xPosition(for: block.startedAt, width: contentWidth, start: start, totalSeconds: totalSeconds)
        let endX = xPosition(for: block.endedAt, width: contentWidth, start: start, totalSeconds: totalSeconds)
        let w = max(2, endX - x)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.secondary.opacity(0.35))
            .frame(width: w, height: idleBarHeight)
            .offset(x: x, y: rowH - idleBarHeight - 4)
            .help(idleTooltip(for: block))
    }

    @ViewBuilder
    private func blockRect(_ block: TimelineBlock,
                           contentWidth: CGFloat,
                           totalSeconds: TimeInterval,
                           start: Date,
                           yPos: CGFloat,
                           height: CGFloat) -> some View {
        let x = xPosition(for: block.startedAt, width: contentWidth, start: start, totalSeconds: totalSeconds)
        let endX = xPosition(for: block.endedAt, width: contentWidth, start: start, totalSeconds: totalSeconds)
        let w = max(3, endX - x)
        let tint = color(for: block)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom))
            blockContent(block, width: w, tint: tint)
        }
        .frame(width: w, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(borderColor(for: block, tint: tint),
                              style: borderStrokeStyle(for: block))
        )
        .shadow(color: tint.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
        .opacity(block.isIgnored ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { closeAgendaPopover(); selectedBlock = block }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip(for: block))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { closeAgendaPopover(); selectedBlock = block }
        .help(tooltip(for: block))
        .popover(isPresented: bindingForPopover(block)) {
            ReattributePopover(block: block,
                               customers: customers,
                               projects: projects,
                               state: state,
                               onSaved: {
                                   selectedBlock = nil
                                   reload()
                               },
                               onCancel: { selectedBlock = nil },
                               onIgnored: { event in
                                   stageUndo(event)
                               })
        }
        // `.position` moves the layout frame (unlike `.offset`), so the popover
        // above anchors to the block instead of the row's origin.
        .position(x: x + w / 2, y: yPos + height / 2)
    }

    @ViewBuilder
    private func blockContent(_ block: TimelineBlock, width: CGFloat, tint: Color) -> some View {
        if width < 26 {
            // Too narrow for anything but a colored sliver.
            EmptyView()
        } else if width < 64 {
            // Just an icon.
            HStack {
                Spacer(minLength: 0)
                blockIcon(block)
                    .frame(width: 18, height: 18)
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                blockIcon(block)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(block.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if width >= 130, let sub = block.subtitle {
                        Text(sub)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .opacity(0.85)
                    }
                }
                Spacer(minLength: 0)
                if block.hasManualOverride, !isIgnoredMeetingBlock(block), width >= 90 {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private func blockIcon(_ block: TimelineBlock) -> some View {
        switch block.track {
        case .foreground:
            if let bundleID = block.appBundleID, let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                glyph("macwindow")
            }
        case .calendar:
            glyph(block.isIgnored ? "eye.slash" : "calendar")
        case .calls:
            glyph(block.isIgnored ? "eye.slash" : "mic.fill")
        case .claudeCode:
            glyph("sparkles")
        }
    }

    @ViewBuilder
    private func glyph(_ name: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.22))
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func bindingForPopover(_ block: TimelineBlock) -> Binding<Bool> {
        Binding(
            get: { selectedBlock?.id == block.id },
            set: { if !$0 { selectedBlock = nil } }
        )
    }

    private func tooltip(for block: TimelineBlock) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let range = "\(f.string(from: block.startedAt))–\(f.string(from: block.endedAt))"
        let attr: String
        if block.isIgnored {
            switch block.track {
            case .calendar:
                attr = block.eventAttribution == .ignored(source: .series)
                    ? "Ignored (series) — click to restore" : "Ignored — click to restore"
            case .calls:
                attr = "Ignored call — restore in Review's Ignored filter"
            default:
                attr = "Ignored repo — restore in Review's Ignored filter"
            }
        } else if let c = block.attribution.customer {
            let base = block.attribution.project.map { "\(c.name) · \($0.name)" } ?? c.name
            if block.track == .claudeCode {
                attr = block.hasManualOverride ? "\(base) (override)" : "\(base) (via repo rule)"
            } else {
                attr = block.hasManualOverride ? "\(base) (override)" : base
            }
        } else {
            attr = block.track == .claudeCode
                ? "Not matched by any rule — click to assign or add a rule in Review"
                : "Unattributed"
        }
        let mins = Int((block.durationSeconds / 60).rounded())
        var parts = ["\(range)  (\(mins)m)  \(attr)", block.title]
        if let sub = block.subtitle { parts.append(sub) }
        return parts.joined(separator: "\n")
    }

    /// True for Claude session blocks that no rule attributed — visually flagged
    /// with a dashed orange border so the user can spot them.
    private func isUnmatchedClaudeBlock(_ block: TimelineBlock) -> Bool {
        block.track == .claudeCode && block.attribution.customer == nil
    }

    /// Calendar block whose event/series is currently ignored. Only emitted
    /// when the reveal toggle is on (see `TimelineBuilder.build`).
    private func isIgnoredMeetingBlock(_ block: TimelineBlock) -> Bool {
        block.track == .calendar && block.isIgnored
    }

    private func borderColor(for block: TimelineBlock, tint: Color) -> Color {
        if block.isIgnored { return Color.secondary.opacity(0.7) }
        if block.hasManualOverride { return Color.white.opacity(0.85) }
        if isUnmatchedClaudeBlock(block) { return Color.orange.opacity(0.7) }
        return tint.opacity(0.55)
    }

    private func borderStrokeStyle(for block: TimelineBlock) -> StrokeStyle {
        if block.isIgnored {
            return StrokeStyle(lineWidth: 1.0, dash: [3, 3])
        }
        if block.hasManualOverride {
            return StrokeStyle(lineWidth: 1.5)
        }
        if isUnmatchedClaudeBlock(block) {
            return StrokeStyle(lineWidth: 1.0, dash: [3, 3])
        }
        return StrokeStyle(lineWidth: 0.5)
    }

    private func idleTooltip(for block: TimelineBlock) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let mins = Int((block.durationSeconds / 60).rounded())
        return "Idle \(f.string(from: block.startedAt))–\(f.string(from: block.endedAt)) (\(mins)m)"
    }

    private func xPosition(for date: Date,
                           width: CGFloat,
                           start: Date,
                           totalSeconds: TimeInterval) -> CGFloat {
        let elapsed = date.timeIntervalSince(start)
        return CGFloat(elapsed / totalSeconds) * width
    }

    private func color(for block: TimelineBlock) -> Color {
        if block.isIgnored { return .gray }
        if let project = block.attribution.project, let c = Color(hex: project.displayColor) { return c }
        if let customer = block.attribution.customer, let c = Color(hex: customer.displayColor) { return c }
        return block.attribution.customer != nil ? .blue : trackTint(block.track).opacity(0.85)
    }

    private func reload() {
        do {
            let allSamples = try state.database.samples(in: dayInterval)
            let rawEvents = try state.database.calendarEvents(in: dayInterval)
            let micSessions = try state.database.micSessions(in: dayInterval)
            let matcher = try RuleMatcher.load(from: state.database)
            let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions, matcher: matcher)
            let sessions = try state.database.sessions(in: dayInterval)
            let claudeDeltas = try state.database.claudeActiveDeltas(in: dayInterval)
            customers = try state.database.allCustomers()
            projects = try state.database.allProjects()
            let hidden = try state.database.allHiddenSignals()
            hasIgnoredMeetings = events.contains { matcher.attribute(event: $0).isIgnored }
                || micSessions.contains { $0.isIgnored }
            // Ignored repos are always drawn (dimmed), so only hidden apps and
            // hosts make the reveal toggle change anything.
            hasHiddenSignals = hidden.contains { $0.kind == .appBundleID || $0.kind == .urlHost }
            let samples = showHidden ? allSamples : TimelineBuilder.visibleSamples(allSamples, hidden: hidden)
            let idleThreshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
            bundle = TimelineBuilder.build(
                day: dayInterval,
                samples: samples,
                events: events,
                sessions: sessions,
                claudeDeltas: claudeDeltas,
                micSessions: micSessions,
                matcher: matcher,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds,
                claudeIdleThresholdSeconds: idleThreshold,
                includeIgnoredEvents: showHidden
            )
            // Day stats from the report's own engine over just this day, so
            // "attributed" here is the report's day column, and "open" is
            // Review's backlog for the day.
            let report = WeeklyReport.compute(
                week: dayInterval, samples: allSamples, events: events, sessions: sessions,
                claudeDeltas: claudeDeltas, micSessions: micSessions,
                idleThresholdSeconds: idleThreshold, matcher: matcher,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds, rounding: AppSettings.reportRounding)
            dayActiveSeconds = report.activeHours * 3600
            dayAttributedSeconds = report.grandTotal * 3600
            let open = try ReviewQueue.build(
                database: state.database, interval: dayInterval,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds,
                idleThresholdSeconds: idleThreshold, minMinutes: AppSettings.reviewMinMinutes)
            dayOpenCount = open.count
            dayOpenSeconds = open.reduce(0) { $0 + $1.totalSeconds }
            dayMeetingSeconds = bundle.calendar.filter { !$0.isIgnored }.reduce(0) { $0 + $1.durationSeconds }
            recomputeDerived()
            loadError = nil
            focusPendingBlock()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Undo toast

    private func stageUndo(_ event: MeetingIgnoreEvent) {
        let entry = PendingUndo(scope: event.scope, subject: event.subject)
        pendingUndo = entry
        pendingUndoDismiss?.cancel()
        pendingUndoDismiss = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if pendingUndo?.id == entry.id { pendingUndo = nil }
            }
        }
    }

    private func performUndo() {
        guard let undo = pendingUndo else { return }
        do {
            switch undo.scope {
            case .event(let id):
                try state.database.setCalendarEventIgnored(eventID: id, isIgnored: false)
            case .series(let id):
                try state.database.setMeetingSeriesAttribution(
                    seriesID: id,
                    customerID: nil,
                    projectID: nil,
                    isIgnored: false
                )
            }
            pendingUndoDismiss?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { pendingUndo = nil }
            reload()
        } catch {
            undoError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let undo = pendingUndo {
            HStack(spacing: 12) {
                Image(systemName: "eye.slash.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toastTitle(for: undo))
                        .font(.callout.weight(.medium))
                    if let undoError {
                        Text(undoError).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    } else {
                        Text(toastSubtitle(for: undo))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Undo") { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button {
                    pendingUndoDismiss?.cancel()
                    withAnimation(.easeInOut(duration: 0.2)) { pendingUndo = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(undo.id)
        }
    }

    private func toastTitle(for undo: PendingUndo) -> String {
        let subject = undo.subject.isEmpty ? "Meeting" : undo.subject
        switch undo.scope {
        case .event: return "Ignored “\(subject)”"
        case .series: return "Ignored every “\(subject)”"
        }
    }

    private func toastSubtitle(for undo: PendingUndo) -> String {
        switch undo.scope {
        case .event: return "Excluded from the weekly report."
        case .series: return "Every occurrence excluded from the weekly report."
        }
    }
}

/// Identifies what was just ignored so the Timeline can surface an undo
/// toast that knows exactly which row to flip back.
struct MeetingIgnoreEvent: Equatable {
    enum Scope: Equatable {
        case event(eventID: String)
        case series(seriesID: String)
    }
    let scope: Scope
    /// Subject used in the toast copy.
    let subject: String
}

private struct ReattributePopover: View {
    let block: TimelineBlock
    let customers: [Customer]
    let projects: [Project]
    let state: AppState
    let onSaved: () -> Void
    let onCancel: () -> Void
    /// Fires after a successful ignore so the Timeline can stage an undo
    /// toast. Restore actions don't fire this — restore *is* the undo.
    let onIgnored: (MeetingIgnoreEvent) -> Void
    /// Further coding sessions a "Just this" pin must reach (an agenda group).
    var extraSessionIDs: [String] = []

    @State private var selectedCustomerID: String = ""
    @State private var selectedProjectID: String = ""
    @State private var scope: AttributionScope = .always
    @State private var error: String?
    @State private var confirmingSeriesIgnore: Bool = false

    /// Non-calendar block with a signal a rule can attach to → offer scope.
    private var showsScope: Bool { !isCalendarBlock && block.ruleSignal != nil }

    private var isCalendarBlock: Bool { block.track == .calendar }
    private var isClaudeBlock: Bool { block.track == .claudeCode }
    private var hasSeries: Bool { block.seriesMasterID != nil }

    /// `true` for any kind of ignored calendar block (event-level or series-level).
    private var isIgnored: Bool { block.eventAttribution?.isIgnored == true }
    private var isEventScopeIgnore: Bool {
        if case .ignored(.event) = block.eventAttribution { return true }
        return false
    }
    private var isSeriesScopeIgnore: Bool {
        if case .ignored(.series) = block.eventAttribution { return true }
        return false
    }

    /// The picker is meaningless for per-event ignored blocks — `event.isIgnored`
    /// beats `event.customerID` in `RuleMatcher.attribute(event:)`, so any
    /// attribution you set wouldn't take effect until you restored first.
    private var showsPicker: Bool { !isEventScopeIgnore }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isClaudeBlock {
                claudeSessionBanner
            } else if isCalendarBlock {
                calendarEventBanner
            }

            Divider()

            if showsPicker {
                AttributionPickerSection(
                    customers: customers,
                    projects: projects,
                    selectedCustomerID: $selectedCustomerID,
                    selectedProjectID: $selectedProjectID,
                    onCreateCustomer: { name in try state.database.createLocalCustomer(name: name) },
                    onCreateProject: { customerID, name in try state.database.createLocalProject(customerID: customerID, name: name) },
                    emptyCustomerLabel: emptyCustomerLabel,
                    error: $error
                )
            }

            if showsScope {
                AttributionScopePicker(
                    scope: $scope,
                    options: AttributionScope.allCases,
                    hint: scope == .justThis
                        ? "Attributes just this block."
                        : "Creates a \(scope == .always ? "permanent" : scope.label.lowercased()) rule for \(block.ruleSignal?.pattern ?? "this signal").")
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if isCalendarBlock {
                calendarFooter
            } else {
                nonCalendarFooter
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            selectedCustomerID = block.attribution.customer?.id ?? ""
            selectedProjectID = block.attribution.project?.id ?? ""
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(block.title).font(.body.bold())
            if let sub = block.subtitle {
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(timeRange).font(.caption.monospaced()).foregroundStyle(.secondary)
            if isCalendarBlock, hasSeries {
                HStack(spacing: 4) {
                    Image(systemName: "repeat").font(.caption2)
                    Text("Part of a recurring series").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let mins = Int((block.durationSeconds / 60).rounded())
        return "\(f.string(from: block.startedAt))–\(f.string(from: block.endedAt))  ·  \(mins) min"
    }

    private var emptyCustomerLabel: String {
        if isClaudeBlock, !block.hasManualOverride {
            return "(use rule)"
        }
        return "Unattributed"
    }

    // MARK: - Banners

    /// Claude session attribution status banner — unchanged behaviour from
    /// before the calendar-event work; just renamed and isolated.
    @ViewBuilder
    private var claudeSessionBanner: some View {
        let repoName = block.title
        if block.hasManualOverride, let customer = block.attribution.customer {
            attributionBanner(
                systemImage: "pin.fill",
                tint: .blue,
                primary: "Manual override active.",
                secondary: "This single session is set to \(displayName(customer: customer, project: block.attribution.project)). Use Clear override to fall back to your repo rule."
            )
        } else if let customer = block.attribution.customer {
            attributionBanner(
                systemImage: "checkmark.seal.fill",
                tint: .green,
                primary: "Attributed via your \(repoName) rule.",
                secondary: "Already counted as \(displayName(customer: customer, project: block.attribution.project)) in the weekly report. To move only this session, pick a customer below and choose Just this."
            )
        } else {
            attributionBanner(
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                primary: "Not matched by any rule.",
                secondary: "Pick a customer below — Always teaches a rule for \(repoName); Just this attributes only this session."
            )
        }
    }

    /// Calendar event attribution status banner. Distinguishes per-event
    /// override, series rule, and the new ignored state.
    @ViewBuilder
    private var calendarEventBanner: some View {
        switch block.eventAttribution {
        case .attributed(let customer, let project, .event):
            attributionBanner(
                systemImage: "pin.fill",
                tint: .blue,
                primary: "Manual override on this occurrence.",
                secondary: hasSeries
                    ? "Set to \(displayName(customer: customer, project: project)). Clear override to fall back to the series rule."
                    : "Set to \(displayName(customer: customer, project: project)). Clear override to leave this meeting unattributed."
            )
        case .attributed(let customer, let project, .series):
            attributionBanner(
                systemImage: "checkmark.seal.fill",
                tint: .green,
                primary: "Attributed via the series rule.",
                secondary: "Counted as \(displayName(customer: customer, project: project)) in the weekly report. Pick a customer below only to override this specific occurrence."
            )
        case .ignored(.event):
            attributionBanner(
                systemImage: "eye.slash.fill",
                tint: .gray,
                primary: "This meeting is ignored.",
                secondary: "Time is excluded from the weekly report. Use Restore this meeting to bring it back."
            )
        case .ignored(.series):
            attributionBanner(
                systemImage: "eye.slash.fill",
                tint: .gray,
                primary: "This series is ignored.",
                secondary: "Every occurrence is excluded from the weekly report. Restore series to bring all of them back, or pick a customer below to include just this occurrence."
            )
        case .unattributed, .none:
            attributionBanner(
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                primary: "Not yet attributed.",
                secondary: hasSeries
                    ? "Use Apply to series to attribute every occurrence at once, or pick a customer below for just this meeting. You can also ignore it."
                    : "Pick a customer below to attribute this meeting, or ignore it to exclude it from the weekly report."
            )
        }
    }

    @ViewBuilder
    private func attributionBanner(systemImage: String, tint: Color, primary: String, secondary: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.caption.bold())
                Text(secondary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func displayName(customer: Customer, project: Project?) -> String {
        if let project { return "\(customer.name) · \(project.name)" }
        return customer.name
    }

    // MARK: - Footers

    @ViewBuilder
    private var nonCalendarFooter: some View {
        HStack {
            Button("Cancel") { onCancel() }
            Spacer()
            Button("Clear override", role: .destructive) {
                apply(customerID: nil, projectID: nil)
            }
            .disabled(!block.hasManualOverride)
            Button("Save") {
                apply(customerID: selectedCustomerID.isEmpty ? nil : selectedCustomerID,
                      projectID: selectedProjectID.isEmpty ? nil : selectedProjectID)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var calendarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            primaryActionRow
            if hasSecondaryRow {
                secondaryActionRow
            }
        }
        .confirmationDialog(
            "Ignore the entire \(seriesConfirmTitle) series?",
            isPresented: $confirmingSeriesIgnore,
            titleVisibility: .visible
        ) {
            Button("Ignore series", role: .destructive) { ignoreSeries() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every occurrence will be excluded from the weekly report. Undo from the toast, or restore later via “Show hidden” on My day.")
        }
    }

    /// Subject used in the confirmation dialog title — `(no subject)` would
    /// read oddly there.
    private var seriesConfirmTitle: String {
        block.title.isEmpty ? "this" : "\(block.title)"
    }

    @ViewBuilder
    private var primaryActionRow: some View {
        HStack {
            Button("Cancel") { onCancel() }
            Spacer()
            if isEventScopeIgnore {
                Button("Restore this meeting") { restoreEvent() }
                    .keyboardShortcut(.defaultAction)
            } else if isSeriesScopeIgnore {
                Button("Save for this meeting") {
                    applyEvent(
                        customerID: selectedCustomerID.isEmpty ? nil : selectedCustomerID,
                        projectID: selectedProjectID.isEmpty ? nil : selectedProjectID
                    )
                }
                .disabled(selectedCustomerID.isEmpty)
                .keyboardShortcut(.defaultAction)
                .help("Override the series ignore for just this occurrence.")
            } else {
                // On a recurring meeting the series is the default action and
                // takes Return; the per-occurrence save is the exception.
                Button("Save for this meeting") {
                    applyEvent(
                        customerID: selectedCustomerID.isEmpty ? nil : selectedCustomerID,
                        projectID: selectedProjectID.isEmpty ? nil : selectedProjectID
                    )
                }
                .keyboardShortcut(hasSeries ? nil : .defaultAction)
                if hasSeries {
                    Button("Apply to series") {
                        applySeries(
                            customerID: selectedCustomerID.isEmpty ? nil : selectedCustomerID,
                            projectID: selectedProjectID.isEmpty ? nil : selectedProjectID
                        )
                    }
                    .disabled(selectedCustomerID.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help("Save this attribution for every occurrence of the series.")
                }
            }
        }
    }

    /// True when the secondary row would render at least one action.
    private var hasSecondaryRow: Bool {
        !isEventScopeIgnore
    }

    @ViewBuilder
    private var secondaryActionRow: some View {
        HStack(spacing: 8) {
            if isSeriesScopeIgnore {
                Button("Restore series") { restoreSeries() }
            } else {
                Button("Ignore this meeting") { ignoreEvent() }
                if hasSeries {
                    Text("·").foregroundStyle(.tertiary)
                    Button("Ignore series") { confirmingSeriesIgnore = true }
                }
                if block.hasManualOverride {
                    Text("·").foregroundStyle(.tertiary)
                    Button("Clear override") {
                        applyEvent(customerID: nil, projectID: nil)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .tint(.red)
    }

    // MARK: - Persistence

    private func apply(customerID: String?, projectID: String?) {
        do {
            // Scoped rule creation (today / this week / always) when the user
            // chose more than "just this block" and we have a signal + customer.
            if scope.createsRule, let sig = block.ruleSignal, let cid = customerID {
                let (validFrom, validTo) = scope.bounds(reference: block.startedAt)
                try state.database.upsertReplacingWindow(Rule(
                    id: UUID().uuidString, customerID: cid, projectID: projectID,
                    kind: sig.kind, pattern: sig.pattern, priority: 100, createdAt: Date(),
                    validFrom: validFrom, validTo: validTo))
                onSaved()
                return
            }
            // "Just this block" (or clearing) → precise per-occurrence override.
            switch block.source {
            case .calendarEvent(let id):
                try state.database.setCalendarEventAttribution(eventID: id, customerID: customerID, projectID: projectID)
            case .claudeSession(let id):
                try state.database.setClaudeSessionAttribution(sessionIDs: [id] + extraSessionIDs, customerID: customerID, projectID: projectID)
            case .foregroundSamples(let ids):
                try state.database.setSampleAttribution(sampleIDs: ids, customerID: customerID, projectID: projectID)
            case .micSession(let id):
                try state.database.setMicSessionAttribution(id: id, customerID: customerID, projectID: projectID)
            }
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func applyEvent(customerID: String?, projectID: String?) {
        guard case .calendarEvent(let id) = block.source else { return }
        do {
            try state.database.setCalendarEventAttribution(eventID: id, customerID: customerID, projectID: projectID)
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func applySeries(customerID: String?, projectID: String?) {
        guard let seriesID = block.seriesMasterID else { return }
        do {
            try state.database.setMeetingSeriesAttribution(
                seriesID: seriesID,
                customerID: customerID,
                projectID: projectID,
                isIgnored: false
            )
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func ignoreEvent() {
        guard case .calendarEvent(let id) = block.source else { return }
        do {
            try state.database.setCalendarEventIgnored(eventID: id, isIgnored: true)
            onIgnored(MeetingIgnoreEvent(scope: .event(eventID: id), subject: block.title))
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func ignoreSeries() {
        guard let seriesID = block.seriesMasterID else { return }
        do {
            try state.database.setMeetingSeriesAttribution(
                seriesID: seriesID,
                customerID: nil,
                projectID: nil,
                isIgnored: true
            )
            onIgnored(MeetingIgnoreEvent(scope: .series(seriesID: seriesID), subject: block.title))
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func restoreEvent() {
        guard case .calendarEvent(let id) = block.source else { return }
        do {
            try state.database.setCalendarEventIgnored(eventID: id, isIgnored: false)
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func restoreSeries() {
        guard let seriesID = block.seriesMasterID else { return }
        do {
            // Clear the row entirely so
            // the series falls back to "no series attribution".
            try state.database.setMeetingSeriesAttribution(
                seriesID: seriesID,
                customerID: nil,
                projectID: nil,
                isIgnored: false
            )
            onSaved()
        } catch let e {
            error = e.localizedDescription
        }
    }
}

// MARK: - Scroll-wheel zoom

/// Transparent view used as a hit-test reference. Installs a local NSEvent
/// monitor while in a window so it can intercept scroll-wheel events whose
/// cursor location falls inside this view, ahead of the SwiftUI ScrollView.
/// Vertical scroll → zoom (consumed); horizontal scroll passes through to pan.
private struct TimelineScrollZoom: NSViewRepresentable {
    let onZoomDelta: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollZoomMonitorView {
        let v = ScrollZoomMonitorView()
        v.onZoomDelta = onZoomDelta
        return v
    }

    func updateNSView(_ nsView: ScrollZoomMonitorView, context: Context) {
        nsView.onZoomDelta = onZoomDelta
    }
}

final class ScrollZoomMonitorView: NSView {
    var onZoomDelta: ((CGFloat) -> Void)?
    // `monitor` is the opaque handle returned by addLocalMonitorForEvents.
    // Stored as Any?; only ever set on the main actor, read in deinit.
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let win = self.window, event.window === win else { return event }
            let pointInView = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(pointInView) else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // Predominantly horizontal gestures fall through so the ScrollView pans.
            guard abs(dy) > abs(dx), dy != 0 else { return event }
            self.onZoomDelta?(dy)
            return nil
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
