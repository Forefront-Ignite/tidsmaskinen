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
        NSApp.setActivationPolicy(.accessory)

        let center = NotificationCenter.default
        // didBecomeKey fires when a Window scene opens via openWindow(id:) and
        // grabs focus. willClose fires when the user dismisses it. Together
        // these cover the policy-switching transitions we care about.
        center.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private nonisolated func windowVisibilityChanged(_ notification: Notification) {
        // NotificationCenter posts can arrive on any thread under Swift 6's
        // stricter rules; hop back to MainActor to access NSApp safely. The
        // deferred dispatch also gives willCloseNotification time to remove
        // the window from NSApp.windows before we count.
        Task { @MainActor [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let hasVisibleAppWindow = NSApp.windows.contains { window in
            // Exclude the MenuBarExtra popover (an NSPanel) and any sheets
            // already counted via their parent. We only care about real
            // top-level app windows.
            window.isVisible && !(window is NSPanel)
        }
        let target: NSApplication.ActivationPolicy = hasVisibleAppWindow ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }
}
