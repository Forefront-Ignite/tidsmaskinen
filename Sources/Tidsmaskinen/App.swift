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

        Window("Tidsmaskinen", id: WindowID.main) {
            MainWindowView()
                .environmentObject(state)
        }
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
    }
}

enum WindowID {
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        // Defer one runloop tick so willCloseNotification has already removed
        // the window from NSApp.windows by the time we count.
        DispatchQueue.main.async { [weak self] in
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
