import Foundation
import AppKit

@MainActor
final class HookIngester {
    static let eventLogFilename = "claude-events.jsonl"
    private static let lastOffsetKey = "hookIngester.lastOffset"

    let database: AppDatabase
    private var fileURL: URL!
    private var stream: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var sleepObserver: NSObjectProtocol?

    var onSessionChanged: ((ClaudeSession) -> Void)?

    init(database: AppDatabase) {
        self.database = database
    }

    func start() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            let dir = appSupport.appendingPathComponent("Tidsmaskinen", isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent(Self.eventLogFilename)
            // Create-or-open atomically so a concurrent first hook can never
            // truncate a log we just created. A failure here is not fatal: the
            // watcher, the poll timer and sleep finalization still install, and
            // reads recover once the file becomes accessible.
            let fd = open(url.path, O_WRONLY | O_CREAT, 0o600)
            if fd >= 0 {
                _ = fchmod(fd, 0o600)
                close(fd)
            }
            self.fileURL = url

            attachWatcher()
            // Catch up on anything already in the file.
            readPending()

            // Safety net: poll every 30 s in case FSEvents misses a write.
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readPending() }
            }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t

            // Finalize any open sessions at sleep time so yesterday's work doesn't
            // bleed into today's buckets when Claude Code finally emits SessionEnd
            // hours later (after wake).
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.finalizeOpenSessionsOnSleep() }
            }
        } catch {
            // Non-fatal; logging not wired here, but we'll just retry later.
        }
    }

    func stop() {
        stream?.cancel()
        stream = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
    }

    private func attachWatcher() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.readPending() }
        }
        // Close the descriptor owned by this source, not a later watcher's descriptor.
        src.setCancelHandler { close(fd) }
        src.resume()
        stream = src
    }

    private func readPending() {
        guard let url = fileURL else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            // Use the actual seek base (0 after truncation, else the saved offset)
            // when persisting the new offset — reusing the pre-truncation value
            // would store base+consumed instead of consumed, causing endless
            // reprocessing on subsequent reads.
            let savedOffset: UInt64 = UInt64(max(0, UserDefaults.standard.integer(forKey: Self.lastOffsetKey)))
            let endOffset = try handle.seekToEnd()
            let seekBase: UInt64
            if endOffset < savedOffset {
                try handle.seek(toOffset: 0)
                seekBase = 0
            } else {
                try handle.seek(toOffset: savedOffset)
                seekBase = savedOffset
            }
            let data = handle.availableData
            if data.isEmpty {
                if seekBase != savedOffset {
                    UserDefaults.standard.set(Int(seekBase), forKey: Self.lastOffsetKey)
                }
                return
            }
            guard var text = String(data: data, encoding: .utf8) else { return }

            // Process complete lines only; if last byte isn't a newline, leave it for next read.
            var consumedBytes = 0
            var lines: [String] = []
            while let nl = text.firstIndex(of: "\n") {
                let line = String(text[..<nl])
                lines.append(line)
                consumedBytes += line.utf8.count + 1  // +1 for the \n
                text.removeSubrange(text.startIndex...nl)
            }
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                handleLine(line)
            }
            UserDefaults.standard.set(Int(seekBase) + consumedBytes, forKey: Self.lastOffsetKey)
        } catch {
            // ignore; next tick will try again
        }
    }

    // MARK: - Parsing + persistence

    private struct Envelope: Decodable {
        let timestamp: String
        let eventType: String
        let payload: Payload?
        let provider: CodingAgentProvider?
    }

    private struct Payload: Decodable {
        let session_id: String?
        let cwd: String?
        let transcript_path: String?
    }

    // Internal (not private) so unit tests can drive ingestion directly without the
    // file watcher / sleep observer that `start()` wires up.
    func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        guard let rawSessionID = envelope.payload?.session_id, !rawSessionID.isEmpty,
              ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "Interrupt"].contains(envelope.eventType),
              let ts = parseISO(envelope.timestamp) else { return }
        let provider = envelope.provider ?? .claude
        let sessionID = provider.storedSessionID(rawSessionID)

        let idleThreshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)

        do {
            let existing = try database.session(id: sessionID)
            // Concurrent hook processes can append out of timestamp order. Never
            // rewind the activity cursor and bill the same gap a second time.
            if let last = existing?.lastActivityAt, ts < last { return }
            if let ended = existing?.endedAt, ts < ended { return }
            // A closed session can legitimately resurrect: a long-lived `claude` session that
            // survived an overnight sleep was closed by sleep-finalization, but the user may keep
            // working in it the next morning under the same session_id. Genuine continuation
            // events (SessionStart / UserPromptSubmit) must reopen it. Terminating events
            // (Stop / SessionEnd) for a closed session, however, are stale — Claude Code emitting
            // SessionEnd after wake would re-bill a second ghost idle gap on top of what
            // sleep-finalize already recorded — so those are still dropped.
            let wasClosed = existing?.endedAt != nil
            if wasClosed {
                switch envelope.eventType {
                case "SessionStart", "UserPromptSubmit":
                    break // resurrect below
                default:
                    return
                }
            }
            var session = existing ?? ClaudeSession(
                id: sessionID,
                cwd: envelope.payload?.cwd,
                transcriptPath: envelope.payload?.transcript_path,
                gitRepoPath: nil,
                gitRemoteURL: nil,
                startedAt: ts,
                endedAt: nil,
                lastActivityAt: nil,
                activeSeconds: 0,
                promptCount: 0,
                customerID: nil,
                projectID: nil,
                createdAt: Date(),
                updatedAt: Date(),
                provider: provider
            )

            // Refresh cwd / transcript if newer payload has them.
            if let cwd = envelope.payload?.cwd, !cwd.isEmpty {
                session.cwd = cwd
                if let root = Probes.findGitRoot(near: cwd) {
                    session.gitRepoPath = root
                    session.gitRemoteURL = Probes.gitOriginURL(repoRoot: root)
                }
            }
            if let tp = envelope.payload?.transcript_path, !tp.isEmpty {
                session.transcriptPath = tp
            }

            // Activity accounting — every recognised event extends activeSeconds,
            // capped by idleThreshold so long idle gaps don't get billed.
            var gainedSeconds: Double = 0
            var activeUntil = ts
            // A reopened session starts fresh; the sleep gap was already finalized.
            if let last = session.lastActivityAt, !wasClosed {
                gainedSeconds = min(ts.timeIntervalSince(last), idleThreshold)
                session.activeSeconds += gainedSeconds
                // Deltas describe [occurredAt - gainedSeconds, occurredAt]. The
                // counted activity is at the start of an idle gap, not its end.
                activeUntil = last.addingTimeInterval(gainedSeconds)
            }
            session.lastActivityAt = ts
            if wasClosed {
                session.endedAt = nil // reopen — the user is continuing this session
            }

            switch envelope.eventType {
            case "SessionStart":
                if existing == nil { session.startedAt = ts }
                session.endedAt = nil
            case "UserPromptSubmit":
                session.promptCount += 1
            case "SessionEnd":
                session.endedAt = ts
            default:
                break
            }
            session.updatedAt = Date()
            try database.upsertSession(session)
            if gainedSeconds > 0 {
                try database.insertClaudeActiveDelta(
                    sessionID: sessionID,
                    occurredAt: activeUntil,
                    gainedSeconds: gainedSeconds)
            }
            onSessionChanged?(session)
        } catch {
            // ignore; next event for this session may recover
        }
    }

    private func finalizeOpenSessionsOnSleep() {
        let sleepAt = Date()
        let idleThreshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
        guard let open = try? database.openSessions() else { return }
        for var session in open {
            let trailing: TimeInterval
            let closeAt: Date
            if let last = session.lastActivityAt {
                let gap = max(0, sleepAt.timeIntervalSince(last))
                trailing = min(gap, idleThreshold)
                closeAt = last.addingTimeInterval(trailing)
            } else {
                trailing = 0
                closeAt = session.startedAt
            }
            session.activeSeconds += trailing
            session.endedAt = closeAt
            session.updatedAt = Date()
            do {
                try database.upsertSession(session)
                if trailing > 0 {
                    try database.insertClaudeActiveDelta(
                        sessionID: session.id,
                        occurredAt: closeAt,
                        gainedSeconds: trailing
                    )
                }
                onSessionChanged?(session)
            } catch {
                // ignore; next sleep cycle will retry
            }
        }
    }

    private func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
