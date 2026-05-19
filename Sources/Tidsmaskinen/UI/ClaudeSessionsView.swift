import SwiftUI

struct ClaudeSessionsView: View {
    @EnvironmentObject private var state: AppState
    @State private var sessions: [ClaudeSession] = []
    @State private var totalCount: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Code sessions").font(.title3.bold())
                Spacer()
                Text("Total: \(totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh") { reload() }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if sessions.isEmpty {
                ContentUnavailableView("No sessions yet",
                                       systemImage: "terminal",
                                       description: Text("Install the hooks in Settings → Claude Code, then start a Claude Code session in any project."))
            } else {
                Table(sessions) {
                    TableColumn("Started") { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.startedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption.monospaced())
                            Text(activeString(s))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 200, ideal: 220)

                    TableColumn("Repo / cwd") { s in
                        if let repo = s.gitRepoPath {
                            Text((repo as NSString).lastPathComponent)
                                .font(.caption.monospaced())
                                .help(s.gitRemoteURL ?? repo)
                        } else if let cwd = s.cwd {
                            Text((cwd as NSString).lastPathComponent)
                                .font(.caption.monospaced())
                                .help(cwd)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Prompts") { s in
                        Text("\(s.promptCount)")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(70)

                    TableColumn("Session ID") { s in
                        Text(s.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Status") { s in
                        statusBadge(s)
                    }
                    .width(min: 110, ideal: 130)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 480)
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
    }

    private func reload() {
        do {
            sessions = try state.database.recentSessions(limit: 200)
            totalCount = try state.database.sessionCount()
        } catch {
            sessions = []
        }
    }

    private func activeString(_ s: ClaudeSession) -> String {
        let threshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
        let active = s.amortizedActiveSeconds(idleThresholdSeconds: threshold)
        return "active \(humanDuration(active))"
    }

    @ViewBuilder
    private func statusBadge(_ s: ClaudeSession) -> some View {
        let threshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
        if s.endedAt != nil {
            HStack(spacing: 4) {
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("Ended").font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if s.isActive(idleThresholdSeconds: threshold) {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").foregroundStyle(Color.green)
                Text("Active").font(.caption)
            }
        } else if let last = s.lastActivityAt {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(Color.orange)
                Text("Idle \(humanDuration(Date().timeIntervalSince(last)))")
                    .font(.caption)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("No activity").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func humanDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}
