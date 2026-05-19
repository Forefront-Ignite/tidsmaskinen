import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var state: AppState
    @State private var events: [CalendarEvent] = []
    @State private var totalCount: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Calendar events")
                    .font(.title3.bold())
                Spacer()
                if state.calendarSync.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let last = state.calendarSync.lastSyncedAt {
                    Text("Last synced \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Total: \(totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await state.calendarSync.syncNow() }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(!state.isSignedIn)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if !state.isSignedIn {
                ContentUnavailableView {
                    Label("Not signed in to Microsoft", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Open the menu bar and click \"Sign in to Microsoft\" to start syncing your Outlook calendar.")
                }
            } else if let err = state.calendarSync.lastError {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .padding()
            } else if events.isEmpty {
                ContentUnavailableView("No events synced yet",
                                       systemImage: "calendar",
                                       description: Text("Click \"Sync now\" to fetch the past + next two weeks."))
            } else {
                Table(events) {
                    TableColumn("When") { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatDate(e.startAt))
                                .font(.caption.monospaced())
                            Text("\(formatTime(e.startAt))–\(formatTime(e.endAt)) · \(e.durationMinutes) min")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 170, ideal: 200)

                    TableColumn("Subject") { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.subject.isEmpty ? "(no subject)" : e.subject)
                                .lineLimit(1)
                            if let org = e.organizerName ?? e.organizerEmail {
                                Text(org).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 200, ideal: 280)

                    TableColumn("Domains") { e in
                        let domains = e.attendeeDomains
                        if domains.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            Text(domains.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("RSVP") { e in
                        Text(rsvpLabel(e.rsvpStatus))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(rsvpColor(e.rsvpStatus).opacity(0.15)))
                            .foregroundStyle(rsvpColor(e.rsvpStatus))
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Online") { e in
                        if e.isOnlineMeeting {
                            Image(systemName: "video.fill").foregroundStyle(.blue)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .width(50)
                }
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
        .onChange(of: state.calendarSync.lastSyncedAt) { _, _ in reload() }
        .onChange(of: state.calendarSync.isSyncing) { _, _ in reload() }
    }

    private func reload() {
        do {
            events = try state.database.recentCalendarEvents(limit: 200)
            totalCount = try state.database.calendarEventCount()
        } catch {
            events = []
        }
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func rsvpLabel(_ status: String) -> String {
        switch status {
        case "accepted": return "Accepted"
        case "tentativelyAccepted": return "Tentative"
        case "declined": return "Declined"
        case "notResponded": return "No reply"
        case "organizer": return "Organizer"
        default: return status
        }
    }

    private func rsvpColor(_ status: String) -> Color {
        switch status {
        case "accepted", "organizer": return .green
        case "tentativelyAccepted": return .orange
        case "declined": return .red
        case "notResponded": return .secondary
        default: return .secondary
        }
    }
}
