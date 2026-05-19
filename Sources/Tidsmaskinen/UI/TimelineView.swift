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

    private let allTracks: [TimelineBlock.Track] = [.calendar, .foreground, .claudeCode]

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
                                    .frame(width: contentWidth, height: rowHeight(for: track))
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
            }
        }
        .frame(minWidth: 1000, minHeight: 540)
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
        }
        .onChange(of: day) { _, _ in reload() }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Button {
                day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
            } label: { Image(systemName: "chevron.left") }

            Text(dayLabel)
                .font(.title3.bold())
                .frame(minWidth: 200, alignment: .leading)

            Button {
                day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            } label: { Image(systemName: "chevron.right") }

            Button("Today") {
                day = Calendar.current.startOfDay(for: Date())
            }
            Spacer()
            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            zoomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f.string(from: day)
    }

    // MARK: - Label column (sticky)

    @ViewBuilder
    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Align with time ruler height.
            Color.clear.frame(height: rulerHeight)
            ForEach(allTracks, id: \.self) { track in
                trackLabel(track)
                    .frame(height: rowHeight(for: track), alignment: .top)
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
        let rowH = rowHeight(for: track)
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
                .strokeBorder(
                    block.hasManualOverride ? Color.white.opacity(0.85) : tint.opacity(0.55),
                    lineWidth: block.hasManualOverride ? 1.5 : 0.5)
        )
        .shadow(color: tint.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { selectedBlock = block }
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
                               onCancel: { selectedBlock = nil })
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
                if block.hasManualOverride, width >= 90 {
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
            glyph("calendar")
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
        let attr = block.attribution.customer.map { c -> String in
            block.attribution.project.map { "\(c.name) · \($0.name)" } ?? c.name
        } ?? "Unattributed"
        let mins = Int((block.durationSeconds / 60).rounded())
        var parts = ["\(range)  (\(mins)m)  \(attr)", block.title]
        if let sub = block.subtitle { parts.append(sub) }
        return parts.joined(separator: "\n")
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
        if let project = block.attribution.project, let c = Color(hex: project.color) { return c }
        if let customer = block.attribution.customer, let c = Color(hex: customer.color) { return c }
        return block.attribution.customer != nil ? .blue : trackTint(block.track).opacity(0.85)
    }

    private func reload() {
        do {
            let samples = try state.database.samples(in: dayInterval)
            let events = try state.database.calendarEvents(in: dayInterval)
            let sessions = try state.database.sessions(in: dayInterval)
            customers = try state.database.allCustomers()
            projects = try state.database.allProjects()
            let rules = try state.database.allRules()
            let matcher = RuleMatcher.make(customers: customers, projects: projects, rules: rules)
            bundle = TimelineBuilder.build(
                day: dayInterval,
                samples: samples,
                events: events,
                sessions: sessions,
                matcher: matcher,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds,
                claudeIdleThresholdSeconds: TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ReattributePopover: View {
    let block: TimelineBlock
    let customers: [Customer]
    let projects: [Project]
    let state: AppState
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var selectedCustomerID: String = ""
    @State private var selectedProjectID: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(block.title).font(.body.bold())
            if let sub = block.subtitle {
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(timeRange).font(.caption.monospaced()).foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Customer").font(.caption.bold())
                Picker("", selection: $selectedCustomerID) {
                    Text("Unassigned").tag("")
                    ForEach(customers) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if !selectedCustomerID.isEmpty {
                let avail = projects.filter { $0.customerID == selectedCustomerID }
                if !avail.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Project").font(.caption.bold())
                        Picker("", selection: $selectedProjectID) {
                            Text("(no project)").tag("")
                            ForEach(avail) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

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
        .padding(16)
        .frame(width: 360)
        .onAppear {
            selectedCustomerID = block.attribution.customer?.id ?? ""
            selectedProjectID = block.attribution.project?.id ?? ""
        }
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let mins = Int((block.durationSeconds / 60).rounded())
        return "\(f.string(from: block.startedAt))–\(f.string(from: block.endedAt))  ·  \(mins) min"
    }

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
    private var monitor: Any?

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
