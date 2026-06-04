import SwiftUI
import AppKit

struct TimelineView: View {
    @EnvironmentObject private var state: AppState

    @State private var day: Date = Calendar.current.startOfDay(for: Date())
    @State private var bundle: TimelineBuilder.DayBundle = TimelineBuilder.DayBundle(calendar: [], foreground: [], claudeCode: [])
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var selectedBlock: TimelineBlock?
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
    /// Block selected from the readable agenda list (separate from `selectedBlock`,
    /// which drives the Gantt-strip popover, so the two popovers never collide).
    @State private var agendaBlock: TimelineBlock?
    /// Derived data cached so it isn't recomputed on every body evaluation
    /// (the view re-renders on 8s/30s timers). Refreshed in `reload()` and when
    /// the foreground-lane toggle changes which tracks are shown.
    @State private var cachedRowHeights: [TimelineBlock.Track: CGFloat] = [:]
    @State private var cachedAgendaBlocks: [TimelineBlock] = []
    @AppStorage(SettingsKey.timelineShowForeground) private var showForeground: Bool = false

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

    private var allTracks: [TimelineBlock.Track] {
        if showForeground {
            return [.calendar, .foreground, .claudeCode]
        }
        return [.calendar, .claudeCode]
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

        let allBlocks = bundle.calendar + bundle.foreground + bundle.claudeCode
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
        .tmWallpaper()
        .overlay(alignment: .bottom) { undoToast }
        .onAppear {
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
        .onChange(of: showForeground) { _, _ in recomputeDerived() }
        .onChange(of: pendingUndo) { _, _ in undoError = nil }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload() }
    }

    // MARK: - Day stats

    private static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// Non-idle blocks across all visible tracks, ordered for the agenda list.
    /// Reads the cache; recomputed only in `recomputeDerived()`.
    private var agendaBlocks: [TimelineBlock] { cachedAgendaBlocks }

    private func computeAgendaBlocks() -> [TimelineBlock] {
        allTracks.flatMap { blocks(for: $0) }
            .filter { !$0.isIdle }
            .sorted { $0.startedAt < $1.startedAt }
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
        cachedAgendaBlocks = computeAgendaBlocks()
    }

    @ViewBuilder
    private var dayStats: some View {
        let active = agendaBlocks.reduce(0.0) { $0 + $1.durationSeconds }
        HStack(spacing: 28) {
            stat(durationLabel(active), "active today")
            stat("\(agendaBlocks.count)", "sources")
            stat("\(allTracks.count)", "tracks")
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
                .scrollIndicators(.hidden)
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
            Text("Timeline · \(dayLabel)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            if agendaBlocks.isEmpty {
                Text("No activity recorded for this day yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(agendaBlocks) { block in
                    agendaRow(block)
                }
            }
        }
    }

    @ViewBuilder
    private func agendaRow(_ block: TimelineBlock) -> some View {
        let tint = color(for: block)
        let attributed = block.attribution.customer != nil
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Self.hhmm.string(from: block.startedAt))–\(Self.hhmm.string(from: block.endedAt))")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(durationLabel(block.durationSeconds))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(width: 104, alignment: .trailing)

            RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: 4, height: 38)

            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(attributed ? 0.18 : 0.10))
                Image(systemName: trackIcon(block.track))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(attributed ? tint : Color.secondary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                if let sub = block.subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            if attributed {
                HStack(spacing: 7) {
                    Circle().fill(tint).frame(width: 10, height: 10)
                    Text(agendaAttributionLabel(block))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                }
            } else {
                Button("Attribute") { selectedBlock = nil; agendaBlock = block }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassCard(radius: 16)
        .contentShape(Rectangle())
        // Clear the Gantt-strip selection so the two popovers can never both open.
        .onTapGesture { selectedBlock = nil; agendaBlock = block }
        .popover(isPresented: agendaPopoverBinding(block)) {
            ReattributePopover(block: block,
                               customers: customers,
                               projects: projects,
                               state: state,
                               onSaved: { agendaBlock = nil; reload() },
                               onCancel: { agendaBlock = nil },
                               onIgnored: { event in agendaBlock = nil; stageUndo(event) })
        }
    }

    private func agendaPopoverBinding(_ block: TimelineBlock) -> Binding<Bool> {
        Binding(get: { agendaBlock?.id == block.id },
                set: { if !$0 { agendaBlock = nil } })
    }

    private func agendaAttributionLabel(_ block: TimelineBlock) -> String {
        guard let c = block.attribution.customer else { return "Unattributed" }
        if let p = block.attribution.project { return "\(c.name) · \(p.name)" }
        return c.name
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
                prevHelp: "Previous day",
                nextHelp: "Next day",
                nowDisabled: isToday,
                onPrev: { day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day },
                onNext: { day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day },
                onNow: { day = Calendar.current.startOfDay(for: Date()) }
            )
            Spacer()
            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            foregroundLaneToggle
            showHiddenToggle
            legendButton
            zoomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var foregroundLaneToggle: some View {
        Button {
            showForeground.toggle()
        } label: {
            Image(systemName: showForeground ? "macwindow.on.rectangle" : "macwindow")
                .foregroundStyle(showForeground ? Color.accentColor : .secondary)
        }
        .help(showForeground
              ? "Hide the foreground app lane"
              : "Show the foreground app lane (per-app activity from your samples)")
    }

    @ViewBuilder
    private var showHiddenToggle: some View {
        Button {
            showHidden.toggle()
        } label: {
            Image(systemName: showHidden ? "eye" : "eye.slash")
                .foregroundStyle(showHidden ? Color.accentColor : .secondary)
        }
        .help(showHidden
              ? "Hide hidden apps, hosts and ignored meetings"
              : "Show hidden apps, hosts and ignored meetings")
        .disabled(!hasHiddenContent)
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
                "Ignored meeting",
                "Dashed grey and faded — excluded from the report. Shown only with the eye toggle on."
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
        case .foreground: return .green
        case .claudeCode: return .pink
        }
    }

    private func trackIcon(_ track: TimelineBlock.Track) -> String {
        switch track {
        case .calendar:   return "calendar"
        case .foreground: return "macwindow"
        case .claudeCode: return "sparkles"
        }
    }

    private func blocks(for track: TimelineBlock.Track) -> [TimelineBlock] {
        switch track {
        case .calendar:   return bundle.calendar
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
        .opacity(isIgnoredMeetingBlock(block) ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { agendaBlock = nil; selectedBlock = block }
        .help(tooltip(for: block))
        .offset(x: x, y: yPos)
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
            glyph(isIgnoredMeetingBlock(block) ? "eye.slash" : "calendar")
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
        if isIgnoredMeetingBlock(block) {
            attr = block.eventAttribution == .ignored(source: .series)
                ? "Ignored (series) — click to restore"
                : "Ignored — click to restore"
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
    /// when the eye toggle is on (see `TimelineBuilder.build`).
    private func isIgnoredMeetingBlock(_ block: TimelineBlock) -> Bool {
        block.eventAttribution?.isIgnored == true
    }

    private func borderColor(for block: TimelineBlock, tint: Color) -> Color {
        if isIgnoredMeetingBlock(block) { return Color.secondary.opacity(0.7) }
        if block.hasManualOverride { return Color.white.opacity(0.85) }
        if isUnmatchedClaudeBlock(block) { return Color.orange.opacity(0.7) }
        return tint.opacity(0.55)
    }

    private func borderStrokeStyle(for block: TimelineBlock) -> StrokeStyle {
        if isIgnoredMeetingBlock(block) {
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
        if isIgnoredMeetingBlock(block) { return .gray }
        if let project = block.attribution.project, let c = Color(hex: project.displayColor) { return c }
        if let customer = block.attribution.customer, let c = Color(hex: customer.displayColor) { return c }
        return block.attribution.customer != nil ? .blue : trackTint(block.track).opacity(0.85)
    }

    private func reload() {
        do {
            let allSamples = try state.database.samples(in: dayInterval)
            let rawEvents = try state.database.calendarEvents(in: dayInterval)
            let micSessions = try state.database.micSessions(in: dayInterval)
            let events = CalendarEvent.withMicOverrun(events: rawEvents, micSessions: micSessions)
            let sessions = try state.database.sessions(in: dayInterval)
            customers = try state.database.allCustomers()
            projects = try state.database.allProjects()
            let rules = try state.database.allRules()
            let allSeries = try state.database.allMeetingSeriesAttributions()
            let matcher = RuleMatcher.make(
                customers: customers,
                projects: projects,
                rules: rules,
                series: allSeries
            )
            hasIgnoredMeetings = events.contains { matcher.attribute(event: $0).isIgnored }
            let hidden = try state.database.allHiddenSignals()
            hasHiddenSignals = !hidden.isEmpty
            let samples: [ActivitySample]
            if showHidden || hidden.isEmpty {
                samples = allSamples
            } else {
                let hiddenApps = Set(hidden.filter { $0.kind == .appBundleID }.map { $0.value })
                let hiddenHosts = Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })
                samples = allSamples.filter { sample in
                    if let bid = sample.appBundleID, hiddenApps.contains(bid) { return false }
                    if let host = sample.chromeHost, hiddenHosts.contains(host) { return false }
                    return true
                }
            }
            bundle = TimelineBuilder.build(
                day: dayInterval,
                samples: samples,
                events: events,
                sessions: sessions,
                matcher: matcher,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds,
                claudeIdleThresholdSeconds: TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60),
                includeIgnoredEvents: showHidden
            )
            recomputeDerived()
            loadError = nil
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

    @State private var selectedCustomerID: String = ""
    @State private var selectedProjectID: String = ""
    @State private var error: String?
    @State private var confirmingSeriesIgnore: Bool = false

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
                secondary: "Already counted as \(displayName(customer: customer, project: block.attribution.project)) in the weekly report. Only pick a customer here if this specific session should go somewhere different."
            )
        } else {
            attributionBanner(
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                primary: "Not matched by any rule.",
                secondary: "Either assign \(repoName) in Review (covers every session in this repo) or pick a customer below to attribute just this session."
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
                if hasSeries {
                    Button("Apply to series") {
                        applySeries(
                            customerID: selectedCustomerID.isEmpty ? nil : selectedCustomerID,
                            projectID: selectedProjectID.isEmpty ? nil : selectedProjectID
                        )
                    }
                    .disabled(selectedCustomerID.isEmpty)
                    .help("Save this attribution for every occurrence of the series.")
                }
                Button("Save for this meeting") {
                    applyEvent(
                        customerID: selectedCustomerID.isEmpty ? nil : selectedCustomerID,
                        projectID: selectedProjectID.isEmpty ? nil : selectedProjectID
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// True when the secondary row would render at least one action.
    private var hasSecondaryRow: Bool {
        if isEventScopeIgnore { return false }
        if isSeriesScopeIgnore { return true } // always has "Restore series"
        // Non-ignored: ignore + clear override possibilities
        if block.hasManualOverride { return true }
        return true // "Ignore this meeting" is always offered
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
            switch block.source {
            case .calendarEvent(let id):
                try state.database.setCalendarEventAttribution(eventID: id, customerID: customerID, projectID: projectID)
            case .claudeSession(let id):
                try state.database.setClaudeSessionAttribution(sessionID: id, customerID: customerID, projectID: projectID)
            case .foregroundSamples(let ids):
                try state.database.setSampleAttribution(sampleIDs: ids, customerID: customerID, projectID: projectID)
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
