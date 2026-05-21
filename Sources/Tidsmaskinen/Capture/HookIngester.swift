import Foundation
import AppKit

@MainActor
final class HookIngester {
    static let eventLogFilename = "claude-events.jsonl"
    private static let lastOffsetKey = "hookIngester.lastOffset"

    let database: AppDatabase
    private var fileURL: URL!
    private var stream: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var watcherFD: Int32 = -1
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
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600])
            } else {
                // Tighten perms in case an earlier build created the file with
                // the default umask.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path)
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
        if watcherFD >= 0 { close(watcherFD); watcherFD = -1 }
        try? fileHandle?.close()
        fileHandle = nil
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
        watcherFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.readPending() }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.watcherFD, fd >= 0 {
                close(fd)
                self?.watcherFD = -1
            }
        }
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
            let savedOffset: UInt64 = UInt64(UserDefaults.standard.integer(forKey: Self.lastOffsetKey))
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
    }

    private struct Payload: Decodable {
        let session_id: String?
        let cwd: String?
        let transcript_path: String?
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        guard let sessionID = envelope.payload?.session_id else { return }

        let ts = parseISO(envelope.timestamp) ?? Date()
        let idleThreshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)

        do {
            let existing = try database.session(id: sessionID)
            // Sessions are closed either by an explicit SessionEnd or by sleep-finalization.
            // Late events for a closed session (e.g. Claude Code emitting SessionEnd after wake)
            // would otherwise add a second 5-min ghost gap on top of what sleep-finalize already
            // recorded. Drop them — Claude Code generates a fresh session_id per CLI invocation,
            // so a closed ID never legitimately resurrects.
            if let existing, existing.endedAt != nil {
                return
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
                updatedAt: Date()
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
            let isActivityEvent: Bool
            switch envelope.eventType {
            case "SessionStart", "UserPromptSubmit", "Stop", "SessionEnd":
                isActivityEvent = true
            default:
                isActivityEvent = false
            }
            var gainedSeconds: Double = 0
            if isActivityEvent {
                if let last = session.lastActivityAt {
                    let gap = max(0, ts.timeIntervalSince(last))
                    gainedSeconds = min(gap, idleThreshold)
                    session.activeSeconds += gainedSeconds
                }
                session.lastActivityAt = ts
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
                    occurredAt: ts,
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
