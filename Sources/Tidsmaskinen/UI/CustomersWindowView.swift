import SwiftUI

struct CustomersWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Tab = .discover

    enum Tab: String, CaseIterable, Identifiable {
        case discover, calls, manage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .discover: return "Discover"
            case .calls: return "Calls"
            case .manage: return "Manage"
            }
        }
        var systemImage: String {
            switch self {
            case .discover: return "sparkles"
            case .calls: return "phone.fill"
            case .manage: return "person.2"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            DiscoverView()
                .environmentObject(state)
                .tabItem { Label(Tab.discover.label, systemImage: Tab.discover.systemImage) }
                .tag(Tab.discover)

            TeamsCallsView()
                .environmentObject(state)
                .tabItem { Label(Tab.calls.label, systemImage: Tab.calls.systemImage) }
                .tag(Tab.calls)

            CustomersView()
                .environmentObject(state)
                .tabItem { Label(Tab.manage.label, systemImage: Tab.manage.systemImage) }
                .tag(Tab.manage)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
