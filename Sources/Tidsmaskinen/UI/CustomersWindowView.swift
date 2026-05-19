import SwiftUI

struct CustomersWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Tab = .discover

    enum Tab: String, CaseIterable, Identifiable {
        case discover, manage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .discover: return "Discover"
            case .manage: return "Manage"
            }
        }
        var systemImage: String {
            switch self {
            case .discover: return "sparkles"
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

            CustomersView()
                .environmentObject(state)
                .tabItem { Label(Tab.manage.label, systemImage: Tab.manage.systemImage) }
                .tag(Tab.manage)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
