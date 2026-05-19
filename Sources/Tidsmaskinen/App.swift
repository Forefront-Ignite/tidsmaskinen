import SwiftUI
import AppKit

@main
struct TidsmaskinenApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: "clock.badge.checkmark")
        }
        .menuBarExtraStyle(.window)

        Window("Raw Samples", id: WindowID.samples) {
            SamplesDebugView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)

        Window("Settings", id: WindowID.settings) {
            SettingsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Customers & Rules", id: WindowID.customers) {
            CustomersWindowView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Weekly Report", id: WindowID.weeklyReport) {
            WeeklyReportView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Diagnostics", id: WindowID.diagnostics) {
            DiagnosticsView()
        }
        .windowResizability(.contentSize)

        Window("Sign in to Microsoft", id: WindowID.signIn) {
            SignInView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Calendar", id: WindowID.calendar) {
            CalendarView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Claude Code sessions", id: WindowID.claudeSessions) {
            ClaudeSessionsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Timeline", id: WindowID.timeline) {
            TimelineView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let samples = "samples"
    static let settings = "settings"
    static let customers = "customers"
    static let weeklyReport = "weeklyReport"
    static let diagnostics = "diagnostics"
    static let signIn = "signIn"
    static let calendar = "calendar"
    static let claudeSessions = "claudeSessions"
    static let timeline = "timeline"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
