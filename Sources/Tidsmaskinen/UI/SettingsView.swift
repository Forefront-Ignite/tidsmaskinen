import SwiftUI
import AppKit

/// Categories for the two-pane Settings layout (macOS System Settings style).
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, tracking, calendar, integrations, ignored
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:      return "General"
        case .tracking:     return "Tracking"
        case .calendar:     return "Calendar"
        case .integrations: return "Integrations"
        case .ignored:      return "Ignored"
        }
    }
    var detail: String {
        switch self {
        case .general:      return "Appearance, startup and updates"
        case .tracking:     return "How activity is sampled"
        case .calendar:     return "Meeting import & Microsoft account"
        case .integrations: return "Command Center & coding agents"
        case .ignored:      return "Repos, hosts and apps you’ve ignored"
        }
    }
    var icon: String {
        switch self {
        case .general:      return "slider.horizontal.3"
        case .tracking:     return "calendar.day.timeline.left"
        case .calendar:     return "calendar"
        case .integrations: return "puzzlepiece.extension"
        case .ignored:      return "eye.slash"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SettingsKey.sampleIntervalSeconds) private var sampleInterval: Int = 15
    @AppStorage(SettingsKey.idleThresholdSeconds) private var idleThreshold: Int = 300
    @AppStorage(SettingsKey.meetingRSVPFilter) private var rsvpFilterRaw: String = MeetingRSVPFilter.acceptedAndTentative.rawValue
    @AppStorage(SettingsKey.graphPreset) private var graphPresetRaw: String = ""
    @AppStorage(SettingsKey.graphClientID) private var graphClientID: String = ""
    @AppStorage(SettingsKey.graphTenantID) private var graphTenantID: String = ""
    @AppStorage(SettingsKey.calendarAutoSyncMinutes) private var autoSyncMinutes: Int = 5
    @AppStorage(SettingsKey.claudeIdleThresholdMinutes) private var claudeIdleMinutes: Int = 5
    @AppStorage(SettingsKey.commandCenterEnabled) private var commandCenterEnabled: Bool = true
    @AppStorage(SettingsKey.commandCenterBaseURL) private var commandCenterBaseURL: String = ""
    @AppStorage(SettingsKey.appearance) private var appearanceRaw: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.reviewMinMinutes) private var reviewMinMinutes: Int = 5
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabled
    @State private var loginItemError: String?
    @State private var commandCenterTokenInput: String = ""
    @State private var commandCenterCustomerCount: Int = 0
    @State private var commandCenterProjectCount: Int = 0

    private var appearanceBinding: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    @State private var category: SettingsCategory = .general
    @State private var hiddenSignals: [HiddenSignal] = []
    @State private var hiddenSignalsError: String?
    @State private var accessibilityTrusted: Bool = Probes.isAccessibilityTrusted(promptIfNeeded: false)

    var body: some View {
        HSplitView {
            categoryRail
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            VStack(alignment: .leading, spacing: 0) {
                paneHeader
                HStack(spacing: 0) {
                    Form { paneContent }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: 640)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { refreshCommandCenterCounts(); reloadHidden(); accessibilityTrusted = Probes.isAccessibilityTrusted(promptIfNeeded: false) }
        .onChange(of: state.commandCenterLastSyncAt) { _, _ in refreshCommandCenterCounts() }
        .onChange(of: category) { _, _ in reloadHidden() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = Probes.isAccessibilityTrusted(promptIfNeeded: false)
            launchAtLogin = LoginItemManager.isEnabled
        }
    }

    // MARK: - Two-pane scaffold

    /// Button-based category list (a plain `List(selection:)` swallowed clicks
    /// here). Styled like the prototype: icon chip + label/detail, accent fill
    /// when active, count badge on Ignored.
    @ViewBuilder
    private var categoryRail: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(SettingsCategory.allCases) { cat in
                    let active = cat == category
                    Button {
                        category = cat
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(active ? Color.white : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background(active ? Color.white.opacity(0.22) : Color.secondary.opacity(0.12),
                                            in: .rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cat.label).font(.system(size: 13.5, weight: .semibold))
                                Text(cat.detail).font(.system(size: 10.5))
                                    .foregroundStyle(active ? Color.white.opacity(0.8) : Color.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if cat == .ignored, !hiddenSignals.isEmpty {
                                Text("\(hiddenSignals.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(active ? Color.white : Color.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(active ? Color.white.opacity(0.25) : Color.secondary.opacity(0.18),
                                                in: Capsule())
                            }
                        }
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(active ? TM.accent : Color.clear, in: .rect(cornerRadius: 11))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .scrollContentBackground(.hidden)
        .background { TMWallpaper().ignoresSafeArea() }
    }

    @ViewBuilder
    private var paneHeader: some View {
        HStack(spacing: 13) {
            Image(systemName: category.icon)
                .font(.system(size: 20))
                .foregroundStyle(TM.accent)
                .frame(width: 42, height: 42)
                .background(TM.accentSoft, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.label).font(.system(size: 19, weight: .bold))
                Text(category.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch category {
        case .general:      generalPane
        case .tracking:     trackingPane
        case .calendar:     calendarPane
        case .integrations: integrationsPane
        case .ignored:      ignoredPane
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var generalPane: some View {
        Section("Appearance") {
            Picker("Theme", selection: appearanceBinding) {
                ForEach(AppTheme.allCases) { theme in
                    Label(theme.label, systemImage: theme.symbol).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            Text("“Auto” follows your macOS appearance — applied to the window, menu bar and tray popover.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if hasUpdateFeed {
            Section("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tidsmaskinen \(appVersionLabel)")
                            .font(.body)
                        Text("Auto-checks daily. Click below to check now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.updaterController.checkForUpdates(nil)
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.down.circle")
                    }
                }
            }
        }

        Section("Permissions") {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text(accessibilityTrusted
                             ? "Granted — window titles & project detection work."
                             : "Needed for window titles and project detection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? TM.positive : .orange)
                }
                Spacer()
                if !accessibilityTrusted {
                    Button("Grant…") {
                        _ = Probes.isAccessibilityTrusted(promptIfNeeded: true)
                        openAccessibilitySettings()
                    }
                }
            }
        }

        Section("Startup") {
            Toggle("Open at login", isOn: launchAtLoginBinding)
            Text(LoginItemManager.statusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let err = loginItemError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var trackingPane: some View {
        Section("Sampling") {
            Stepper(value: $sampleInterval, in: 5...300, step: 5) {
                LabeledContent("Sample interval") {
                    Text("\(sampleInterval) s")
                        .monospacedDigit()
                }
            }
            Stepper(value: $idleThreshold, in: 60...1800, step: 30) {
                LabeledContent("Idle threshold") {
                    Text(formatDuration(idleThreshold))
                        .monospacedDigit()
                }
            }
            Text("Above this many seconds without input, samples are tagged as idle (still recorded but excluded from billable time by default).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Attribution") {
            Text("Meetings and concurrent work each contribute to their assigned customer. Reported hours can exceed elapsed time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Review & Discover") {
            Stepper(value: $reviewMinMinutes, in: 0...60, step: 1) {
                LabeledContent("Hide items under") {
                    Text(reviewMinMinutes == 0 ? "off" : "\(reviewMinMinutes) min").monospacedDigit()
                }
            }
            Text("Items shorter than this are hidden from Review and Discover (0 shows everything). Default 5 min filters out short bursts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var calendarPane: some View {
        Section("Meetings") {
            Picker("RSVP filter", selection: rsvpFilterBinding) {
                ForEach(MeetingRSVPFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            Text("The RSVP filter controls which saved meetings appear in the app; changing it keeps your assignments. Declined meetings are shown under \"All invites\" but never bill. Meetings count for their booked duration even when you are idle; attendance is not verified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $autoSyncMinutes, in: 0...60, step: 1) {
                LabeledContent("Auto-sync every") {
                    Text(autoSyncMinutes == 0 ? "disabled" : "\(autoSyncMinutes) min")
                        .monospacedDigit()
                }
            }
            Text("Set to 0 to disable auto-sync; you can still hit Sync now manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Microsoft account") {
            Picker("Preset", selection: presetBinding) {
                ForEach(GraphPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            LabeledContent("Client ID") {
                TextField("Application (client) ID", text: $graphClientID, prompt: Text(AppSettings.defaultGraphClientID))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(minWidth: 320)
                    .disabled(presetBinding.wrappedValue != .custom)
            }
            LabeledContent("Tenant") {
                TextField("Tenant ID, domain, or 'common'", text: $graphTenantID, prompt: Text(AppSettings.defaultGraphTenantID))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(minWidth: 320)
                    .disabled(presetBinding.wrappedValue != .custom)
            }
            Text("Forefront preset uses our shared Entra app registration with Calendars.Read + User.Read consent. Switch to Custom to paste your own Application (client) ID and tenant.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if state.isSignedIn {
                    Label(state.signedInPrincipal ?? "Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(TM.positive).font(.callout)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await state.signOut() }
                    } label: { Text("Sign out") }
                } else {
                    Label("Not connected", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button {
                        state.showSignIn = true
                    } label: { Label("Sign in to Microsoft", systemImage: "person.crop.circle.badge.plus") }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text("Changing the preset, Client ID or Tenant invalidates the cached refresh token. Sign out and sign in again after editing.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var integrationsPane: some View {
        Section("Command Center") {
            commandCenterSection
        }
        Section("Claude Code") {
            AgentHookSettingsView(provider: .claude)
        }
        Section("Codex (OpenAI)") {
            AgentHookSettingsView(provider: .codex)
        }
        Section("Coding session activity") {
            Stepper(value: $claudeIdleMinutes, in: 1...60, step: 1) {
                LabeledContent("Session idle threshold") {
                    Text("\(claudeIdleMinutes) min").monospacedDigit()
                }
            }
            Text("Applies to both Claude Code and Codex. Only the first \(claudeIdleMinutes) minutes of a gap between hook events count as active time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ignoredPane: some View {
        Section("Ignored items") {
            if let hiddenSignalsError {
                Text(hiddenSignalsError).font(.caption).foregroundStyle(.red)
            }
            if hiddenSignals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing ignored").font(.body.weight(.semibold))
                    Text("In Review or Discover, choose “Ignore” on private git repos, shared hosts or anything that isn’t client work — it won’t be asked again. Ignored meetings are managed in Review and My day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(hiddenSignals) { signal in
                    HStack(spacing: 10) {
                        Image(systemName: signal.kind.systemImage)
                            .foregroundStyle(.secondary)
                        Text(signal.value).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Un-ignore") { unhide(signal) }
                    }
                }
                Text("Ignored hosts and apps are excluded from Review and the Timeline. Ignored repos also exclude their app and coding-agent activity from reports, for all dates. Recorded data is kept so you can un-ignore later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reloadHidden() {
        do {
            hiddenSignals = try state.database.allHiddenSignals()
            hiddenSignalsError = nil
        } catch {
            hiddenSignalsError = error.localizedDescription
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func unhide(_ signal: HiddenSignal) {
        do {
            try state.database.unhide(id: signal.id)
            reloadHidden()
        } catch {
            hiddenSignalsError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var commandCenterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Sync customers & projects from Command Center", isOn: $commandCenterEnabled)

            if state.commandCenterTokenInvalid {
                Label("Token rejected — paste a fresh one below.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                SecureField(
                    state.commandCenterHasToken ? "Token saved (paste to replace)" : "Paste API token (cc_…)",
                    text: $commandCenterTokenInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                Button("Save") {
                    let token = commandCenterTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    state.saveCommandCenterToken(token)
                    commandCenterTokenInput = ""
                }
                .disabled(commandCenterTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if state.commandCenterHasToken {
                    Button(role: .destructive) {
                        state.clearCommandCenterToken()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 8) {
                if let url = portalSettingsURL {
                    Link(destination: url) {
                        Label("Generate a token in Command Center", systemImage: "arrow.up.right.square")
                    }
                    .font(.caption)
                }
                Text("Tokens are stored in the macOS Keychain and sent to the configured Command Center API to authenticate requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Base URL",
                      text: $commandCenterBaseURL,
                      prompt: Text(AppSettings.defaultCommandCenterBaseURL))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            HStack {
                if state.commandCenterIsSyncing {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                } else if let lastSync = state.commandCenterLastSyncAt {
                    Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not synced yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.refreshCommandCenter() }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(!state.commandCenterHasToken || state.commandCenterIsSyncing || !commandCenterEnabled)
            }

            if commandCenterCustomerCount > 0 || commandCenterProjectCount > 0 {
                Text("\(commandCenterCustomerCount) customer\(commandCenterCustomerCount == 1 ? "" : "s"), \(commandCenterProjectCount) project\(commandCenterProjectCount == 1 ? "" : "s") from Command Center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = state.commandCenterLastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // Dev builds ship without SUFeedURL; hiding the Updates section avoids
    // Sparkle's "no feed URL" alert. Mirrors MenuBarView.hasUpdateFeed.
    private var hasUpdateFeed: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (v?, b?) where v != b: return "v\(v) (\(b))"
        case let (v?, _):                return "v\(v)"
        case let (_, b?):                return "build \(b)"
        default:                          return ""
        }
    }

    private func refreshCommandCenterCounts() {
        commandCenterCustomerCount = (try? state.database.externalCustomerCount(source: .commandCenter)) ?? 0
        commandCenterProjectCount = (try? state.database.externalProjectCount(source: .commandCenter)) ?? 0
    }

    /// Derives the portal token-settings page from the configured API base URL.
    /// `api.ignitestudio.eu` → `app.ignitestudio.eu`; anything else (e.g. localhost
    /// dev) gets `/me/settings` appended verbatim. Returns nil for unparseable URLs.
    private var portalSettingsURL: URL? {
        let base = commandCenterBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettings.defaultCommandCenterBaseURL
            : commandCenterBaseURL
        guard var components = URLComponents(string: base) else { return nil }
        if let host = components.host, host.hasPrefix("api.") {
            components.host = "app." + host.dropFirst("api.".count)
        }
        components.path = "/me/settings"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LoginItemManager.setEnabled(newValue)
                    loginItemError = nil
                } catch {
                    loginItemError = error.localizedDescription
                }
                launchAtLogin = LoginItemManager.isEnabled
            }
        )
    }

    private var presetBinding: Binding<GraphPreset> {
        Binding(
            get: {
                if let preset = GraphPreset(rawValue: graphPresetRaw) { return preset }
                let inferred = GraphPreset.match(clientID: AppSettings.graphClientID, tenantID: AppSettings.graphTenantID)
                return inferred
            },
            set: { newValue in
                graphPresetRaw = newValue.rawValue
                switch newValue {
                case .custom:
                    break  // keep current text fields
                default:
                    graphClientID = newValue.clientID ?? ""
                    graphTenantID = newValue.tenantID ?? ""
                }
            }
        )
    }

    private var rsvpFilterBinding: Binding<MeetingRSVPFilter> {
        Binding(
            get: { MeetingRSVPFilter(rawValue: rsvpFilterRaw) ?? .acceptedAndTentative },
            set: { rsvpFilterRaw = $0.rawValue }
        )
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes) min" }
        return "\(minutes) min \(remainder) s"
    }
}

private struct AgentHookSettingsView: View {
    let provider: CodingAgentProvider
    @State private var hookState: HookInstaller.InstallState = .notInstalled
    @State private var hookActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch hookState {
                case .installed(let path):
                    Label("Hooks configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Spacer()
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .notInstalled:
                    Label("Hooks not installed", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                case .stale(let installed, _):
                    Label("Hooks need refreshing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(installed)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .error(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button {
                    do {
                        hookState = try HookInstaller.install(provider: provider)
                        hookActionError = nil
                    } catch {
                        hookActionError = error.localizedDescription
                    }
                } label: {
                    Label("Install / refresh hooks", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    do {
                        hookState = try HookInstaller.uninstall(provider: provider)
                        hookActionError = nil
                    } catch {
                        hookActionError = error.localizedDescription
                    }
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .disabled(hookState == .notInstalled)
            }

            if let err = hookActionError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Text("Tracks active time, prompt counts and project attribution from new sessions.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Hook configuration: \(HookInstaller.settingsPath(for: provider).path)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if provider == .codex {
                Text("After installing or refreshing, restart Codex and review and trust the Tidsmaskinen hooks using /hooks in the Codex CLI. Requires a Codex version with lifecycle hook support.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { hookState = HookInstaller.currentState(provider: provider) }
    }
}
