import SwiftUI

struct SampleBlock: Identifiable {
    let id: String
    let firstAt: Date
    let lastAt: Date
    let count: Int
    let appBundleID: String?
    let appName: String?
    let windowTitle: String?
    let chromeHost: String?
    let gitRepoPath: String?
    let isIdle: Bool

    var duration: TimeInterval {
        // Last sample's at-time + one sample interval covers the window of the last sample.
        let interval = TimeInterval(AppSettings.sampleIntervalSeconds)
        return max(interval, lastAt.timeIntervalSince(firstAt) + interval)
    }

    static func group(_ samples: [ActivitySample], maxGap: TimeInterval = 60) -> [SampleBlock] {
        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
        var blocks: [SampleBlock] = []
        for sample in sorted {
            if let last = blocks.last,
               sameIdentity(last, sample),
               sample.capturedAt.timeIntervalSince(last.lastAt) <= maxGap {
                blocks[blocks.count - 1] = SampleBlock(
                    id: last.id,
                    firstAt: last.firstAt,
                    lastAt: sample.capturedAt,
                    count: last.count + 1,
                    appBundleID: last.appBundleID,
                    appName: last.appName,
                    windowTitle: last.windowTitle,
                    chromeHost: last.chromeHost,
                    gitRepoPath: last.gitRepoPath,
                    isIdle: last.isIdle
                )
            } else {
                blocks.append(SampleBlock(
                    id: sample.id.map(String.init) ?? UUID().uuidString,
                    firstAt: sample.capturedAt,
                    lastAt: sample.capturedAt,
                    count: 1,
                    appBundleID: sample.appBundleID,
                    appName: sample.appName,
                    windowTitle: sample.windowTitle,
                    chromeHost: sample.chromeHost,
                    gitRepoPath: sample.gitRepoPath,
                    isIdle: sample.isIdle
                ))
            }
        }
        return blocks.reversed()
    }

    private static func sameIdentity(_ block: SampleBlock, _ sample: ActivitySample) -> Bool {
        block.appBundleID == sample.appBundleID
            && block.windowTitle == sample.windowTitle
            && block.chromeHost == sample.chromeHost
            && block.gitRepoPath == sample.gitRepoPath
            && block.isIdle == sample.isIdle
    }
}

struct SamplesDebugView: View {
    @EnvironmentObject private var state: AppState
    @State private var samples: [ActivitySample] = []
    @State private var blocks: [SampleBlock] = []
    @State private var totalCount: Int = 0
    @State private var grouped: Bool = true
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent activity")
                    .font(.title3.bold())
                Spacer()
                Toggle("Grouped", isOn: $grouped)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("Total: \(totalCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Refresh") { reload() }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if grouped {
                blocksTable
            } else {
                rawTable
            }
        }
        .onAppear {
            reload()
            let t = Timer(timeInterval: 5, repeats: true) { _ in
                Task { @MainActor in reload() }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: state.sampleCount) { _, _ in reload() }
    }

    @ViewBuilder
    private var blocksTable: some View {
        Table(blocks) {
            TableColumn("Time") { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatRange(b.firstAt, b.lastAt))
                        .font(.caption.monospaced())
                    Text(formatDuration(b.duration) + " · \(b.count)×")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 170, ideal: 200)

            TableColumn("App") { b in
                Text(b.appName ?? "—")
            }
            .width(min: 110, ideal: 140)

            TableColumn("Window title") { b in
                Text(b.windowTitle ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(b.windowTitle == nil ? Color.secondary : Color.primary)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Repo / Host") { b in
                if let host = b.chromeHost {
                    Text(host).font(.caption.monospaced())
                } else if let repo = b.gitRepoPath {
                    Text((repo as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .help(repo)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Idle") { b in
                Image(systemName: b.isIdle ? "moon.zzz.fill" : "circle.fill")
                    .foregroundStyle(b.isIdle ? Color.secondary : Color.green)
            }
            .width(40)
        }
    }

    @ViewBuilder
    private var rawTable: some View {
        Table(samples) {
            TableColumn("Time") { s in
                Text(s.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
            }
            .width(min: 90, ideal: 100)

            TableColumn("App") { s in
                Text(s.appName ?? s.appBundleID ?? "—")
            }
            .width(min: 110, ideal: 140)

            TableColumn("Window title") { s in
                Text(s.windowTitle ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(s.windowTitle == nil ? Color.secondary : Color.primary)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Repo / Host") { s in
                if let host = s.chromeHost {
                    Text(host).font(.caption.monospaced())
                } else if let repo = s.gitRepoPath {
                    Text((repo as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .help(repo)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Idle") { s in
                Image(systemName: s.isIdle ? "moon.zzz.fill" : "circle.fill")
                    .foregroundStyle(s.isIdle ? Color.secondary : Color.green)
            }
            .width(40)
        }
    }

    private func formatRange(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        if Calendar.current.isDate(start, inSameDayAs: Date()) == false {
            // Show day prefix when not today.
            let withDay = DateFormatter()
            withDay.dateFormat = "d MMM HH:mm"
            return "\(withDay.string(from: start)) → \(f.string(from: end))"
        }
        return "\(f.string(from: start)) → \(f.string(from: end))"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }

    private func reload() {
        do {
            samples = try state.database.recentSamples(limit: 500)
            blocks = SampleBlock.group(samples)
            totalCount = try state.database.sampleCount()
        } catch {
            samples = []
            blocks = []
        }
    }
}
