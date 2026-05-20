import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for "Open at login" support. Requires the
/// running binary to be a properly-bundled `.app` (the `bin/make-app.sh`
/// output, not `swift run`). The user can revoke approval at any time from
/// System Settings → General → Login Items & Extensions.
enum LoginItemManager {
    /// True when macOS will launch Tidsmaskinen at login. Includes the
    /// `.requiresApproval` state so the toggle reflects user intent even
    /// while the system is waiting for approval.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Tidsmaskinen will launch automatically when you log in."
        case .requiresApproval:
            return "Approval needed in System Settings → General → Login Items & Extensions."
        case .notRegistered:
            return "Off. Toggle on to launch Tidsmaskinen automatically at login."
        case .notFound:
            return "Login-item registration not available for this binary. Make sure you launched the bundled .app, not `swift run`."
        @unknown default:
            return "Unknown login-item status."
        }
    }

    /// Registers or unregisters Tidsmaskinen as a login item. Throws if the
    /// system refuses (typically because the binary isn't a proper .app).
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
