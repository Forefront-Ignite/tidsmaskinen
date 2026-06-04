import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var accessibilityTrusted = Probes.isAccessibilityTrusted(promptIfNeeded: false)
    @State private var permissionPollTimer: Timer?

    var body: some View {
        VStack(spacing: 10) {
            header
            nowCard
            integrationCard
            if !accessibilityTrusted {
                permissionsBanner
            }
            if let err = state.lastError {
                errorBanner(err)
            }
            actionTiles
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AppMark.badge(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tidsmaskinen")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text("Tracking since \(state.startedAt.formatted(date: .omitted, time: .shortened)) · \(state.sampleCount) samples")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Now card

    private var nowCard: some View {
        HStack(alignment: .top, spacing: 12) {
            appIconView
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    statusDot
                    Text(state.latestSample?.appName ?? state.latestSample?.appBundleID ?? "Waiting for first sample…")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let title = state.latestSample?.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let chip = contextChipText {
                    HStack(spacing: 4) {
                        Image(systemName: contextChipIcon)
                            .font(.system(size: 9, weight: .medium))
                        Text(chip)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.primary.opacity(0.6))
                }
                if let s = state.latestSample {
                    Text("Last sample \(s.capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var statusDot: some View {
        let isActive = state.latestSample != nil && !(state.latestSample?.isIdle ?? true)
        return Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(isActive ? Color.green : Color.secondary)
            .symbolEffect(.pulse, options: .repeating, isActive: isActive)
    }

    private var appIconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
            if let icon = currentAppIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: state.latestSample?.isIdle == true ? "moon.zzz.fill" : "app.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func currentAppIcon() -> NSImage? {
        guard let bundleID = state.latestSample?.appBundleID else { return nil }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private var contextChipText: String? {
        if let host = state.latestSample?.chromeHost { return host }
        if let repo = state.latestSample?.gitRepoPath { return (repo as NSString).lastPathComponent }
        return nil
    }

    private var contextChipIcon: String {
        if state.latestSample?.chromeHost != nil { return "globe" }
        return "chevron.left.forwardslash.chevron.right"
    }

    // MARK: - Integration card

    private var integrationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.isSignedIn ? Color.green.opacity(0.18) : Color.secondary.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: state.isSignedIn ? "checkmark" : "person.crop.circle.dashed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.isSignedIn ? Color.green : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microsoft 365")
                        .font(.callout.weight(.semibold))
                    Group {
                        if let p = state.signedInPrincipal {
                            Text(p)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Sign in to sync your Outlook calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                }
                Spacer(minLength: 0)
                if state.isSignedIn {
                    Button("Sign out") { Task { await state.signOut() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Sign in") {
                        state.showSignIn = true
                        openMain()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            if state.isSignedIn {
                HStack(spacing: 6) {
                    Button {
                        open(.calendar)
                    } label: {
                        Label("Calendar", systemImage: "calendar")
                    }
                    .controlSize(.small)
                    Button {
                        Task { await state.calendarSync.syncNow() }
                    } label: {
                        if state.calendarSync.isSyncing {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Syncing")
                            }
                        } else {
                            Label("Sync now", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(state.calendarSync.isSyncing)
                    Spacer()
                    if let last = state.calendarSync.lastSyncedAt {
                        Text(last.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary.opacity(0.6))
                    }
                }
                .font(.caption)
                if let err = state.calendarSync.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if state.calendarSync.lastSyncedAt != nil {
                    Text("Last sync · \(state.calendarSync.lastFetchedCount) fetched, \(state.calendarSync.lastDeletedCount) removed")
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Banners

    private var permissionsBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access needed")
                    .font(.caption.weight(.semibold))
                Text("Window titles and project detection require Accessibility. Restart after granting.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Grant…") {
                _ = Probes.isAccessibilityTrusted(promptIfNeeded: true)
                openAccessibilitySettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Action tiles

    private var actionTiles: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
            spacing: 6
        ) {
            tile(for: .weeklyReport)
            tile(for: .timeline)
            tile(for: .review)
            tile(for: .calls)
        }
    }

    private func tile(for item: SidebarItem) -> some View {
        actionTile(item.title, systemImage: item.systemImage, tint: item.tint) {
            open(item)
        }
    }

    private func actionTile(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            footerIcon("Settings", systemImage: "gearshape.fill") { open(.settings) }
            footerIcon("Diagnostics", systemImage: "stethoscope") { open(.diagnostics) }
            if hasUpdateFeed {
                footerIcon("Check for Updates", systemImage: "arrow.down.circle") {
                    state.updaterController.checkForUpdates(nil)
                }
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quit").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(.secondary)
                .background(
                    Capsule().fill(Color.primary.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func footerIcon(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }

    // MARK: - Shared

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary.opacity(0.6))
    }

    // Dev builds ship without SUFeedURL; hiding the button avoids surfacing
    // Sparkle's "no feed URL" alert when someone clicks it locally.
    private var hasUpdateFeed: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private func open(_ section: SidebarItem) {
        state.selectedSection = section
        openMain()
    }

    private func openMain() {
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                accessibilityTrusted = Probes.isAccessibilityTrusted(promptIfNeeded: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionPollTimer = t
    }

    private func stopPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }
}

// MARK: - Button styles

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileLabel(configuration: configuration)
    }

    private struct TileLabel: View {
        let configuration: TileButtonStyle.Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? Color.primary.opacity(0.12)
                                : (hover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                        )
                )
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: IconButtonStyle.Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? Color.primary.opacity(0.14)
                                : (hover ? Color.primary.opacity(0.09) : Color.clear)
                        )
                )
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}
