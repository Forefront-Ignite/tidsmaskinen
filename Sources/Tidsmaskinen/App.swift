import SwiftUI
import AppKit

@main
struct TidsmaskinenApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var state = AppState()
    // Drives the app-wide appearance (Light / Dark / Auto). Stored so it
    // applies before first paint and persists across launches.
    @AppStorage(SettingsKey.appearance) private var appearanceRaw = AppTheme.system.rawValue

    private var colorScheme: ColorScheme? {
        AppTheme(rawValue: appearanceRaw)?.colorScheme
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .preferredColorScheme(colorScheme)
        } label: {
            // Monochrome segmented-clock mark — the design's tray glyph.
            // Must be a template NSImage; a SwiftUI Canvas doesn't render here.
            Image(nsImage: AppMark.trayImage)
        }
        .menuBarExtraStyle(.window)

        Window("Tidsmaskinen", id: WindowID.main) {
            MainWindowView()
                .environmentObject(state)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
        // Each view renders its own header; hide the system title bar so the
        // title isn't shown twice and the glass content runs full-height.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Wire the standard ⌘, slot to open the main window on the Settings
            // section. This app has no Settings scene (Settings is a sidebar
            // item), so without this the system shortcut would do nothing once
            // a window is key.
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(state: state)
            }
        }
    }
}

/// "Settings…" menu command (⌘,) that opens the main window focused on the
/// Settings section. Lives in a view so it can read the `openWindow` action.
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    let state: AppState

    var body: some View {
        Button("Settings…") {
            state.selectedSection = .settings
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

enum WindowID {
    static let main = "main"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplicationDelegateAdaptor instantiates this from a generic context
    // that doesn't get to assume MainActor isolation.
    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent only: never take a Dock slot, even while a window is
        // open. Windows still activate via NSApp.activate(ignoringOtherApps:)
        // and key equivalents (⌘C/⌘V/⌘W/⌘Q) still dispatch through the main
        // menu even though accessory apps don't display it.
        NSApp.setActivationPolicy(.accessory)
    }
}
