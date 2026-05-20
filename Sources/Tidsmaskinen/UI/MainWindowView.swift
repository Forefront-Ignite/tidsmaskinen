import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case weeklyReport
    case timeline
    case calendar
    case discover
    case calls
    case customers
    case claudeSessions
    case settings
    case diagnostics
    case samples

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weeklyReport:   return "Weekly Report"
        case .timeline:       return "Timeline"
        case .calendar:       return "Calendar"
        case .discover:       return "Discover"
        case .calls:          return "Calls"
        case .customers:      return "Customers"
        case .claudeSessions: return "Claude Sessions"
        case .settings:       return "Settings"
        case .diagnostics:    return "Diagnostics"
        case .samples:        return "Raw Samples"
        }
    }

    var systemImage: String {
        switch self {
        case .weeklyReport:   return "chart.bar.doc.horizontal.fill"
        case .timeline:       return "calendar.day.timeline.left"
        case .calendar:       return "calendar"
        case .discover:       return "sparkles"
        case .calls:          return "phone.fill"
        case .customers:      return "person.2.fill"
        case .claudeSessions: return "wand.and.stars"
        case .settings:       return "gearshape.fill"
        case .diagnostics:    return "stethoscope"
        case .samples:        return "list.bullet.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .weeklyReport:   return .blue
        case .timeline:       return .orange
        case .calendar:       return .teal
        case .discover:       return .yellow
        case .calls:          return .green
        case .customers:      return .purple
        case .claudeSessions: return .pink
        case .settings:       return .gray
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
            case .reports: return [.weeklyReport, .timeline, .calendar]
            case .sources: return [.discover, .calls, .customers, .claudeSessions]
            case .system:  return [.settings, .diagnostics, .samples]
            }
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selectedSection) {
                ForEach(SidebarItem.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(item.tint)
                            }
                            .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .labelStyle(.titleAndIcon)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .navigationTitle(state.selectedSection.title)
        }
        .frame(minWidth: 900, minHeight: 580)
        .sheet(isPresented: $state.showSignIn) {
            SignInView()
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedSection {
        case .weeklyReport:   WeeklyReportView()
        case .timeline:       TimelineView()
        case .calendar:       CalendarView()
        case .discover:       DiscoverView()
        case .calls:          TeamsCallsView()
        case .customers:      CustomersView()
        case .claudeSessions: ClaudeSessionsView()
        case .settings:       SettingsView()
        case .diagnostics:    DiagnosticsView()
        case .samples:        SamplesDebugView()
        }
    }
}
