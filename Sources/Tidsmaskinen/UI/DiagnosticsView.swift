import SwiftUI
import AppKit

struct DiagnosticsView: View {
    @State private var diagnostics: Probes.Diagnostics = Probes.runDiagnostics()
    @State private var lastRun: Date = Date()
    @State private var lastRequestStatus: String?
    @State private var lastResetMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                permissionsSection

                Divider()

                frontmostSection

                Divider()

                editorSection

                Divider()

                chromeSection

                if !diagnostics.notes.isEmpty {
                    Divider()
                    notesSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 540)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Probe diagnostics").font(.title2.bold())
            Spacer()
            Text("Last run \(lastRun.formatted(date: .omitted, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                diagnostics = Probes.runDiagnostics()
                lastRun = Date()
            } label: {
                Label("Run probes now", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        sectionHeader("Permissions")
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            permissionRow(
                title: "Accessibility",
                granted: diagnostics.accessibilityTrusted,
                openURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                helpText: "Required for window titles and editor document paths."
            )
            permissionRow(
                title: "Automation → Google Chrome",
                granted: diagnostics.chromeError == nil && diagnostics.capturedChromeURL != nil,
                openURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
                helpText: "Required to read the active Chrome tab URL. Automation can't be requested directly — first AppleScript call triggers the prompt."
            )
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, openURL: String, helpText: String) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Text(title).bold()
            }
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Button("Open Settings") {
                if let url = URL(string: openURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var frontmostSection: some View {
        sectionHeader("Frontmost app at probe time")
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
            kvRow("Name", diagnostics.frontmostName ?? "—")
            kvRow("Bundle ID", diagnostics.frontmostBundleID ?? "—", monospaced: true)
            kvRow("PID", diagnostics.frontmostPID.map(String.init) ?? "—", monospaced: true)
        }
    }

    @ViewBuilder
    private var editorSection: some View {
        sectionHeader("Code editor probe")
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
            kvRow("Window title", diagnostics.capturedWindowTitle ?? "—")
            kvRow("Document (AXDocument)", diagnostics.capturedDocumentPath ?? "—", monospaced: true)
            kvRow("Git root", diagnostics.capturedGitRoot ?? "—", monospaced: true)
            kvRow("Origin URL", diagnostics.capturedGitOrigin ?? "—", monospaced: true)
        }
        Text("Repo is captured only when a file is focused in VS Code/Cursor (sidebar, welcome screen, extensions tab → no AXDocument → no repo).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var chromeSection: some View {
        sectionHeader("Chrome probe")
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
            kvRow("Chrome running?", diagnostics.chromeRunning ? "yes" : "no")
            kvRow("Active tab URL", diagnostics.capturedChromeURL ?? "—", monospaced: true)
            if let err = diagnostics.chromeError, diagnostics.capturedChromeURL == nil {
                GridRow(alignment: .top) {
                    Text("Error").bold().gridColumnAlignment(.trailing)
                    Text(err)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }

        HStack(spacing: 10) {
            Button {
                let status = Probes.requestAutomationPermission(forBundle: Probes.chromeBundleID, prompt: true)
                lastRequestStatus = status.displayString
                diagnostics = Probes.runDiagnostics()
                lastRun = Date()
            } label: {
                Label("Request Chrome access", systemImage: "checkmark.shield")
            }
            Button(role: .destructive) {
                resetChromePermission()
            } label: {
                Label("Reset & re-prompt", systemImage: "arrow.counterclockwise.circle")
            }
        }
        if let status = lastRequestStatus {
            Text("Permission request: \(status)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        if let msg = lastResetMessage {
            Text(msg)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }

        Text("\"Request Chrome access\" calls AEDeterminePermissionToAutomateTarget directly, which is the most reliable way to surface the macOS prompt. \"Reset & re-prompt\" runs `tccutil reset AppleEvents se.forefront.tidsmaskinen` so the prompt fires again on next request.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func resetChromePermission() {
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "AppleEvents", "se.forefront.tidsmaskinen"]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            lastResetMessage = task.terminationStatus == 0
                ? "Permission reset OK. Click \"Request Chrome access\" to re-prompt."
                : "tccutil failed (status \(task.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            lastResetMessage = "tccutil error: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        sectionHeader("Notes")
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(diagnostics.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    Text(note)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    @ViewBuilder
    private func kvRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).bold().gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
        }
    }
}
