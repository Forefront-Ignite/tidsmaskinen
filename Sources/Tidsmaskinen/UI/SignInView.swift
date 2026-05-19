import SwiftUI
import AppKit

struct SignInView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case idle
        case requesting
        case awaiting(DeviceCodeResponse)
        case completed(GraphMe)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Microsoft").font(.title2.bold())

            switch phase {
            case .idle:
                idleView
            case .requesting:
                ProgressView("Requesting device code…")
            case .awaiting(let response):
                awaitingView(response)
            case .completed(let me):
                completedView(me)
            case .failed(let msg):
                failedView(msg)
            }

            Spacer()

            HStack {
                Spacer()
                if case .completed = phase {
                    Button("Done") { closeAndCleanup() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { closeAndCleanup() }
                }
            }
        }
        .padding(20)
        .frame(width: 500, height: 380)
        .onAppear {
            // Auto-start the device-code flow — the user already opted in by
            // clicking "Sign in" in the menu bar, no reason to make them click
            // again.
            if case .idle = phase { beginFlow() }
        }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var idleView: some View {
        Text("This will read your Outlook/Office 365 calendar so meetings can be matched to customers. Sign-in uses Microsoft's device-code flow — no password is given to Tidsmaskinen.")
            .font(.body)
            .foregroundStyle(.secondary)
        Button {
            beginFlow()
        } label: {
            Label("Get sign-in code", systemImage: "lock.shield")
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func awaitingView(_ response: DeviceCodeResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Visit this URL and enter the code:")
                .font(.body)
                .foregroundStyle(.secondary)
            HStack {
                Text(response.verificationUri)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("Open") {
                    if let url = URL(string: response.verificationUri) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            HStack(spacing: 12) {
                Text(response.userCode)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response.userCode, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Waiting for you to approve sign-in…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func completedView(_ me: GraphMe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("Signed in as \(me.displayName ?? me.userPrincipalName)").font(.body.bold())
            }
            Text(me.userPrincipalName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("You can now sync your calendar from the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.red)
                Text("Sign-in failed").font(.body.bold())
            }
            ScrollView {
                Text(message)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            Button("Try again") { phase = .idle }
        }
    }

    private func beginFlow() {
        phase = .requesting
        pollTask = Task { @MainActor in
            do {
                let response = try await state.graph.requestDeviceCode()
                phase = .awaiting(response)
                let tokens = try await state.graph.pollForTokens(deviceCode: response.deviceCode, interval: response.interval)
                _ = tokens
                let me = try await state.graph.me()
                state.didSignIn(principal: me.userPrincipalName)
                phase = .completed(me)
            } catch {
                phase = .failed("\(error)")
            }
        }
    }

    private func closeAndCleanup() {
        pollTask?.cancel()
        dismiss()
    }
}
