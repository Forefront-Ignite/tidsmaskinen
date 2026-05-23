import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SettingsKey.sampleIntervalSeconds) private var sampleInterval: Int = 15
    @AppStorage(SettingsKey.idleThresholdSeconds) private var idleThreshold: Int = 300
    @AppStorage(SettingsKey.trackIdleDuringMeetings) private var trackIdleDuringMeetings: Bool = true
    @AppStorage(SettingsKey.meetingRSVPFilter) private var rsvpFilterRaw: String = MeetingRSVPFilter.acceptedAndTentative.rawValue
    @AppStorage(SettingsKey.verifyMeetingAttendance) private var verifyAttendance: Bool = false
    @AppStorage(SettingsKey.parallelAttribution) private var parallelAttribution: Bool = true
    @AppStorage(SettingsKey.graphClientID) private var graphClientID: String = ""
    @AppStorage(SettingsKey.graphTenantID) private var graphTenantID: String = ""
    @AppStorage(SettingsKey.calendarAutoSyncMinutes) private var autoSyncMinutes: Int = 5
    @AppStorage(SettingsKey.claudeIdleThresholdMinutes) private var claudeIdleMinutes: Int = 5
    @AppStorage(SettingsKey.commandCenterEnabled) private var commandCenterEnabled: Bool = true
    @AppStorage(SettingsKey.commandCenterBaseURL) private var commandCenterBaseURL: String = ""
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabled
    @State private var loginItemError: String?
    @State private var commandCenterTokenInput: String = ""
    @State private var commandCenterCustomerCount: Int = 0
    @State private var commandCenterProjectCount: Int = 0

    var body: some View {
        Form {
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

            Section("Meetings") {
                Picker("RSVP filter", selection: rsvpFilterBinding) {
                    ForEach(MeetingRSVPFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                Toggle("Keep recording during meetings even when idle", isOn: $trackIdleDuringMeetings)
                Toggle("Verify attendance via meeting-app activity (Zoom/Teams/Webex/Meet)", isOn: $verifyAttendance)
                Text("Only events matching the RSVP filter are imported. Verification adds a badge but does not exclude events.")
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

            Section("Attribution") {
                Toggle("Parallel attribution (count meeting + foreground separately)", isOn: $parallelAttribution)
                Text("Off: only one customer billed per minute. On: a meeting and concurrent coding both attribute to their own customers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                claudeCodeSection
            }

            Section("Command Center") {
                commandCenterSection
            }

            Section("Microsoft Graph") {
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
                    Spacer()
                    if state.isSignedIn {
                        Button(role: .destructive) {
                            Task { await state.signOut() }
                        } label: {
                            Text("Sign out (\(state.signedInPrincipal ?? ""))")
                        }
                    }
                }
                Text("Changing the preset, Client ID or Tenant invalidates the cached refresh token. Sign out and sign in again after editing.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 600, minHeight: 640)
        .padding(.horizontal, 4)
        .onAppear { refreshCommandCenterCounts() }
        .onChange(of: state.commandCenterLastSyncAt) { _, _ in refreshCommandCenterCounts() }
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
                Text("Tokens are stored in the macOS Keychain and never leave this Mac.")
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

    @State private var hookState: HookInstaller.InstallState = HookInstaller.currentState()
    @State private var hookActionError: String?

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

    @ViewBuilder
    private var claudeCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch hookState {
                case .installed(let path):
                    Label("Hooks installed", systemImage: "checkmark.circle.fill")
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
                    Label("Hooks point to a stale path", systemImage: "exclamationmark.triangle.fill")
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
                        hookState = try HookInstaller.install()
                        hookActionError = nil
                    } catch {
                        hookActionError = error.localizedDescription
                    }
                } label: {
                    Label("Install / refresh hooks", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    do {
                        hookState = try HookInstaller.uninstall()
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

            Stepper(value: $claudeIdleMinutes, in: 1...60, step: 1) {
                LabeledContent("Session idle threshold") {
                    Text("\(claudeIdleMinutes) min").monospacedDigit()
                }
            }
            Text("A Claude Code session is considered idle after this many minutes without a hook event. Idle gaps don't contribute to billable hours — only the first \(claudeIdleMinutes) min of any silent stretch counts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Writes to ~/.claude/settings.json. Other hook entries you've added are preserved — only our SessionStart / SessionEnd / UserPromptSubmit / Stop lines are added or removed. Hook events end up in claude-events.jsonl and are ingested live.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presetBinding: Binding<GraphPreset> {
        Binding(
            get: {
                let stored = AppSettings.defaults.string(forKey: SettingsKey.graphPreset)
                if let stored, let preset = GraphPreset(rawValue: stored) { return preset }
                let inferred = GraphPreset.match(clientID: AppSettings.graphClientID, tenantID: AppSettings.graphTenantID)
                return inferred
            },
            set: { newValue in
                AppSettings.defaults.set(newValue.rawValue, forKey: SettingsKey.graphPreset)
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
