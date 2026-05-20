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
    @AppStorage(SettingsKey.aiModel) private var aiModel: String = AppSettings.defaultAIModel
    @AppStorage(SettingsKey.aiAuthMode) private var aiAuthModeRaw: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyStatus: String = ""
    @State private var didLoadApiKey: Bool = false
    @State private var detectedClaudePath: String? = nil
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
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

            Section("AI Suggestions") {
                aiSection
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
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Auth", selection: authModeBinding) {
                ForEach(AIAuthMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            switch authModeBinding.wrappedValue {
            case .claudeCodeCLI:
                claudeCLIRow
            case .apiKey:
                apiKeyRow
            }

            Picker("Model", selection: $aiModel) {
                Text("Sonnet 4.6 (balanced)").tag("claude-sonnet-4-6")
                Text("Opus 4.7 (most accurate)").tag("claude-opus-4-7")
                Text("Haiku 4.5 (fastest)").tag("claude-haiku-4-5-20251001")
            }
            Text("Used by Discover's \"Suggest with AI\" button to map unassigned signals to customers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            detectedClaudePath = ClaudeCLIDetector.findClaudeBinary()
            if !didLoadApiKey {
                if let existing = KeychainStore.getData(account: ClaudeAPI.apiKeyAccount)
                    .flatMap({ String(data: $0, encoding: .utf8) }), !existing.isEmpty {
                    apiKeyStatus = "•••• \(String(existing.suffix(4)))"
                } else {
                    apiKeyStatus = "Not set"
                }
                didLoadApiKey = true
            }
        }
    }

    @ViewBuilder
    private var claudeCLIRow: some View {
        HStack(spacing: 6) {
            if let path = detectedClaudePath {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                Text("Detected `claude` at").font(.caption)
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                Text("Could not find `claude` in common paths. Install Claude Code (npm i -g @anthropic-ai/claude-code) or switch to API key mode.")
                    .font(.caption)
            }
            Spacer()
            Button("Re-detect") { detectedClaudePath = ClaudeCLIDetector.findClaudeBinary() }
                .controlSize(.small)
        }
        Text("Uses your existing Claude Code login (Pro / Max / Premium seat). Calls shell out to `claude -p` — slightly slower than the API but no separate billing.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        LabeledContent("API key") {
            SecureField("sk-ant-…", text: $apiKeyDraft, prompt: Text(apiKeyStatus.isEmpty ? "Not set" : apiKeyStatus))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(minWidth: 320)
        }
        HStack {
            Button("Save key") {
                let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    apiKeyStatus = "Empty"
                } else if let data = trimmed.data(using: .utf8),
                          (try? KeychainStore.setData(data, account: ClaudeAPI.apiKeyAccount)) != nil {
                    apiKeyStatus = "Saved (•••• \(String(trimmed.suffix(4))))"
                    apiKeyDraft = ""
                } else {
                    apiKeyStatus = "Save failed"
                }
            }
            .disabled(apiKeyDraft.isEmpty)
            Button(role: .destructive) {
                KeychainStore.delete(account: ClaudeAPI.apiKeyAccount)
                apiKeyStatus = "Cleared"
            } label: { Text("Remove") }
            Spacer()
            Text(apiKeyStatus).font(.caption).foregroundStyle(.secondary)
        }
        Text("Billed against your console.anthropic.com credits — separate from any claude.ai subscription. Key stays in your macOS Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var authModeBinding: Binding<AIAuthMode> {
        Binding(
            get: { AppSettings.aiAuthMode },
            set: { aiAuthModeRaw = $0.rawValue }
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
