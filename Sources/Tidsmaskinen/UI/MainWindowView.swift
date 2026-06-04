import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case weeklyReport
    case timeline
    case review
    case discover
    case calls
    case customers
    case debug
    case settings
    // Debug sub-screens — reachable via the Debug hub, not the sidebar.
    case calendar
    case claudeSessions
    case diagnostics
    case samples

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weeklyReport:   return "Weekly Report"
        case .timeline:       return "My day"
        case .review:         return "Review"
        case .discover:       return "Discover"
        case .calls:          return "Calls"
        case .customers:      return "Customers"
        case .debug:          return "Debug"
        case .settings:       return "Settings"
        case .calendar:       return "Calendar"
        case .claudeSessions: return "Claude Sessions"
        case .diagnostics:    return "Diagnostics"
        case .samples:        return "Raw Samples"
        }
    }

    var systemImage: String {
        switch self {
        case .weeklyReport:   return "chart.bar.doc.horizontal.fill"
        case .timeline:       return "calendar.day.timeline.left"
        case .review:         return "sparkles"
        case .discover:       return "square.grid.2x2.fill"
        case .calls:          return "phone.fill"
        case .customers:      return "person.2.fill"
        case .debug:          return "wrench.and.screwdriver.fill"
        case .settings:       return "gearshape.fill"
        case .calendar:       return "calendar"
        case .claudeSessions: return "wand.and.stars"
        case .diagnostics:    return "stethoscope"
        case .samples:        return "list.bullet.rectangle"
        }
    }

    /// Name in the ported `DesignIcon` set, or nil to fall back to the SF Symbol.
    var designIcon: String? {
        switch self {
        case .weeklyReport: return "report"
        case .timeline:     return "myday"
        case .review:       return "review"
        case .discover:     return "discover"
        case .calls:        return "call"
        case .customers:    return "people"
        case .settings:     return "sliders"
        default:            return nil   // debug + hidden sub-screens use SF Symbols
        }
    }

    var tint: Color {
        switch self {
        case .weeklyReport:   return .blue
        case .timeline:       return .orange
        case .review:         return Color(hex: "#5b54ff") ?? .indigo
        case .discover:       return .teal
        case .calls:          return .green
        case .customers:      return .purple
        case .debug:          return .secondary
        case .settings:       return .gray
        case .calendar:       return .teal
        case .claudeSessions: return .pink
        case .diagnostics:    return .red
        case .samples:        return .secondary
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case reports, sources, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reports: return "Reports"
            case .sources: return "Sources"
            case .system:  return "System"
            }
        }
        var items: [SidebarItem] {
            switch self {
            case .reports: return [.weeklyReport, .timeline]
            case .sources: return [.review, .discover, .calls, .customers]
            case .system:  return [.debug, .settings]
            }
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TMWallpaper().ignoresSafeArea() }
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .frame(minWidth: 940, minHeight: 600)
        .sheet(isPresented: $state.showSignIn) {
            SignInView()
                .environmentObject(state)
        }
    }

    // Sidebar: a brand mark header + the native selectable list, made
    // translucent so the window wallpaper reads through it (glass rail look).
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppMark.badge(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tidsmaskinen").font(.system(size: 14, weight: .bold))
                    Text("Tracking since \(state.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SidebarItem.Group.allCases) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(group.items) { item in
                            navRow(item)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollContentBackground(.hidden)
        }
        .background { TMWallpaper().ignoresSafeArea() }
    }

    @ViewBuilder
    private func navRow(_ item: SidebarItem) -> some View {
        let isSel = state.selectedSection == item
        Button {
            state.selectedSection = item
        } label: {
            HStack(spacing: 11) {
                Group {
                    if let icon = item.designIcon {
                        DesignIcon(name: icon, size: 19, color: isSel ? TM.accent : .secondary)
                    } else {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 15))
                            .foregroundStyle(isSel ? TM.accent : .secondary)
                            .frame(width: 19, height: 19)
                    }
                }
                Text(item.title)
                    .font(.system(size: 13.5, weight: isSel ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isSel ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedSection {
        case .weeklyReport:   WeeklyReportView()
        case .timeline:       TimelineView()
        case .review:         ReviewView()
        case .discover:       DiscoverView()
        case .calls:          TeamsCallsView()
        case .customers:      CustomersView()
        case .debug:          DebugHubView()
        case .settings:       SettingsView()
        // Direct routes (also reachable from the Debug hub).
        case .calendar:       CalendarView()
        case .claudeSessions: ClaudeSessionsView()
        case .diagnostics:    DiagnosticsView()
        case .samples:        SamplesDebugView()
        }
    }
}

/// Collects the developer/diagnostic screens behind one sidebar entry so the
/// main navigation stays focused on the day-to-day surfaces.
struct DebugHubView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case calendar, claudeSessions, samples, diagnostics
        var id: String { rawValue }
        var item: SidebarItem {
            switch self {
            case .calendar:       return .calendar
            case .claudeSessions: return .claudeSessions
            case .samples:        return .samples
            case .diagnostics:    return .diagnostics
            }
        }
    }
    @State private var tab: Tab = .calendar

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug").font(.system(size: 24, weight: .bold))
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Label(t.item.title, systemImage: t.item.systemImage).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            Divider()
            Group {
                switch tab {
                case .calendar:       CalendarView()
                case .claudeSessions: ClaudeSessionsView()
                case .samples:        SamplesDebugView()
                case .diagnostics:    DiagnosticsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
