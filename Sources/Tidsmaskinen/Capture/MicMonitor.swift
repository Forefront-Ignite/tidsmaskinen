import Foundation
import CoreAudio
import AppKit
import Darwin

enum MicDebug {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tidsmaskinen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mic-debug.log", isDirectory: false)
    }()
    // ISO8601DateFormatter isn't Sendable but is only touched from the
    // serial `mic-debug` queue below, so concurrent access is impossible.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "mic-debug")

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// Polls the default audio input device to detect when the microphone is
/// being used by any app (the same signal that drives the orange dot in the
/// macOS menu bar). Surfaces start/end events for VoIP-like sessions and
/// persists them as MicSession rows.
///
/// CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` is the public
/// indicator that *some* process is reading from the device — we don't get
/// to know which one. So at session start we snapshot which known VoIP apps
/// are running (Teams, Zoom, Slack, Webex, Discord, FaceTime). If none of
/// them are running we still record the session but flag it as "Other mic
/// activity" — that covers dictation, Voice Memos, Whisper, podcast tools.
@MainActor
final class MicMonitor {
    let database: AppDatabase
    var onSessionStart: ((MicSession) -> Void)?
    var onSessionEnd: ((MicSession) -> Void)?

    private var timer: Timer?
    private var pollInterval: TimeInterval = 5.0

    private var isRecording: Bool = false
    private var currentSessionID: String?
    private var currentSessionStart: Date?
    private var currentSessionRecorderBundles: Set<String> = []

    /// Window titles read directly off the Slack/Teams process via the
    /// Accessibility API on each poll while the mic is hot — independent of
    /// which app is frontmost. These are the primary source for the session's
    /// Slack channel / Teams participant; foreground samples are the fallback.
    private var sessionSlackTitles: [String] = []
    private var sessionTeamsTitles: [String] = []

    /// When `isRunningInput` briefly goes false mid-call (camera toggle, BT
    /// headset switch, app audio-pipeline restart) we don't close the session
    /// immediately — we wait for this grace window to expire with no recorder.
    /// Polls happen every 5 s, so 12 s covers typical 2-cycle dropouts.
    private let graceDuration: TimeInterval = 12.0
    private var gracePeriodEnds: Date?

    // SwiftUI can instantiate the `@StateObject AppState` autoclosure more than
    // once during process startup, which historically produced duplicate
    // MicSession rows (one per parallel monitor). Track the active instance
    // process-wide so only the first MicMonitor owns the timer; the rest are
    // inert.
    private static weak var active: MicMonitor?

    nonisolated private static let voipBundleIDs: [String: String] = [
        "com.microsoft.teams":              "Teams",
        "com.microsoft.teams2":             "Teams",
        // Teams 2.x captures audio inside helper subprocesses with their own
        // bundle IDs — keep them mapped in case the parent-walk falls back.
        "com.microsoft.teams2.modulehost":  "Teams",
        "com.microsoft.teams2.helper":      "Teams",
        "com.microsoft.teams2.notificationcenter": "Teams",
        "us.zoom.xos":                      "Zoom",
        "com.tinyspeck.slackmacgap":        "Slack",
        "com.tinyspeck.slackmacgap.helper": "Slack",
        "com.cisco.webexmeetingsapp":       "Webex",
        "cisco-systems.spark":              "Webex",
        "com.webex.meetingmanager":         "Webex",
        "com.hnc.discord":                  "Discord",
        "com.apple.facetime":               "FaceTime",
        "com.google.chrome":                "Chrome",
        "com.brave.browser":                "Brave",
        "company.thebrowser.browser":       "Arc",
        "com.apple.safari":                 "Safari",
        // Non-VoIP but common mic users — labelling them helps the user
        // recognise false positives in the Calls tab.
        "com.apple.voicememos":             "Voice Memos",
        "com.apple.speechrecognitioncore":  "Dictation",
        "com.apple.assistantd":             "Siri",
        "com.apple.sirincservice":          "Siri",
        "com.apple.quicktimeplayerx":       "QuickTime",
        "com.apple.photobooth":             "Photo Booth",
        "com.openai.chat":                  "ChatGPT"
    ]

    init(database: AppDatabase) {
        self.database = database
    }

    func start() {
        guard timer == nil else { return }
        if let other = Self.active, other !== self { return }
        Self.active = self

        MicDebug.log("MicMonitor.start() pollInterval=\(pollInterval)s")

        // On startup, close any orphan sessions from a prior crash/force-quit.
        try? database.closeOrphanedMicSessions(currentlyRunningSessionID: nil)

        // Take an initial reading so a call already in progress is captured.
        poll()

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        timer?.invalidate()
        timer = nil
        // If we're shutting down mid-session, close it cleanly.
        if let id = currentSessionID, let start = currentSessionStart {
            let end = Date()
            let finalApps = Array(currentSessionRecorderBundles).sorted()
            let (participant, slackChannel) = inferContext(
                recorderBundles: currentSessionRecorderBundles, start: start, end: end, db: database)
            try? database.endMicSession(id: id, endedAt: end, participant: participant, slackChannel: slackChannel, voipApps: finalApps)
            let s = MicSession(id: id, startedAt: start, endedAt: end,
                               voipAppsCSV: finalApps.isEmpty ? nil : finalApps.joined(separator: ","),
                               participant: participant, slackChannel: slackChannel,
                               customerID: nil, projectID: nil,
                               createdAt: start, updatedAt: end)
            onSessionEnd?(s)
        }
        currentSessionID = nil
        currentSessionStart = nil
        currentSessionRecorderBundles = []
        sessionSlackTitles = []
        sessionTeamsTitles = []
        isRecording = false
    }

    private func poll() {
        // Process-level signal is more accurate than `IsRunningSomewhere` on
        // the device, which stays true while an app is releasing the device.
        let recorders = currentInputRecorders()
        let activeBundles = Set(recorders.compactMap { $0.bundleID })
        let now = Date()

        if !activeBundles.isEmpty {
            // Some app is currently recording.
            gracePeriodEnds = nil
            if isRecording {
                // Mid-session. If the new recorder set shares no apps with
                // what we've accumulated so far, it's a different call (e.g.
                // Slack ended within grace and Teams started just after) —
                // close the current session and start fresh.
                if currentSessionRecorderBundles.intersection(activeBundles).isEmpty {
                    endSession()
                    beginSession(with: recorders)
                } else {
                    for b in activeBundles { currentSessionRecorderBundles.insert(b) }
                }
            } else {
                beginSession(with: recorders)
                isRecording = true
            }
            // Snapshot the call's window context live, regardless of frontmost
            // app, so a huddle/call attributes even while the user works
            // elsewhere.
            accumulateCallContext(from: recorders)
        } else {
            // Mic is currently off according to process-level signal.
            guard isRecording else { return }
            if let graceEnd = gracePeriodEnds {
                if now >= graceEnd {
                    endSession()
                    isRecording = false
                    gracePeriodEnds = nil
                }
                // else: still inside the grace window — leave session open.
            } else {
                gracePeriodEnds = now.addingTimeInterval(graceDuration)
            }
        }
    }

    private func beginSession(with recorders: [Recorder] = []) {
        let db = database
        let start = Date()
        // The caller passes the recorder set that triggered the transition;
        // if it's empty (defensive path) we fall back to "currently running
        // VoIP apps" so we at least tag something.
        let initialBundles = recorders.compactMap { $0.bundleID }
        let apps = initialBundles.isEmpty ? runningVoipBundleIDs() : initialBundles
        currentSessionRecorderBundles = Set(apps)
        sessionSlackTitles = []
        sessionTeamsTitles = []
        do {
            let id = try db.startMicSession(at: start, voipApps: apps)
            currentSessionID = id
            currentSessionStart = start
            let s = MicSession(id: id, startedAt: start, endedAt: nil,
                               voipAppsCSV: apps.isEmpty ? nil : apps.joined(separator: ","),
                               participant: nil, slackChannel: nil,
                               customerID: nil, projectID: nil,
                               createdAt: start, updatedAt: start)
            onSessionStart?(s)
        } catch {
            MicDebug.log("MicMonitor: failed to start session: \(error)")
        }
    }

    private func endSession() {
        guard let id = currentSessionID, let start = currentSessionStart else { return }
        let db = database
        let end = Date()
        let finalApps = Array(currentSessionRecorderBundles).sorted()
        let (participant, slackChannel) = inferContext(
            recorderBundles: currentSessionRecorderBundles, start: start, end: end, db: db)
        do {
            try db.endMicSession(id: id, endedAt: end, participant: participant, slackChannel: slackChannel, voipApps: finalApps)
            let s = MicSession(id: id, startedAt: start, endedAt: end,
                               voipAppsCSV: finalApps.isEmpty ? nil : finalApps.joined(separator: ","),
                               participant: participant, slackChannel: slackChannel,
                               customerID: nil, projectID: nil,
                               createdAt: start, updatedAt: end)
            onSessionEnd?(s)
        } catch {
            MicDebug.log("MicMonitor: failed to end session: \(error)")
        }
        currentSessionID = nil
        currentSessionStart = nil
        currentSessionRecorderBundles = []
        sessionSlackTitles = []
        sessionTeamsTitles = []
    }

    /// Reads the live window titles of the Slack/Teams process(es) currently
    /// holding the mic and appends them to the session buffers. Uses the
    /// owning-app PID we already resolved, so it works even when the call app
    /// is in the background. No-op without Accessibility (returns empty).
    /// Dedupes owning PIDs per poll so a main app + its helper don't
    /// double-count.
    private func accumulateCallContext(from recorders: [Recorder]) {
        var slackPIDs: Set<pid_t> = []
        var teamsPIDs: Set<pid_t> = []
        for r in recorders {
            guard let bid = r.bundleID else { continue }
            if bid.contains("slack") { slackPIDs.insert(r.ownerPID) }
            else if bid.contains("teams") { teamsPIDs.insert(r.ownerPID) }
        }
        for pid in slackPIDs { sessionSlackTitles.append(contentsOf: Probes.allWindowTitles(pid: pid)) }
        for pid in teamsPIDs { sessionTeamsTitles.append(contentsOf: Probes.allWindowTitles(pid: pid)) }
    }

    /// Resolves the session's Teams participant and Slack channel. Live AX-read
    /// titles win; foreground samples are the fallback — but only for an app
    /// that *actually held the mic* (`recorderBundles`). Without that gate,
    /// foreground Teams activity during a Slack huddle gets misattributed as the
    /// call's participant (and vice-versa) — the title would then read e.g. a
    /// Teams channel name on what was really a Slack huddle.
    private func inferContext(recorderBundles: Set<String>, start: Date, end: Date, db: AppDatabase)
        -> (participant: String?, slackChannel: String?) {
        let teamsRecorded = recorderBundles.contains { $0.contains("teams") }
        let slackRecorded = recorderBundles.contains { $0.contains("slack") }
        let slackChannel = MicSession.bestSlackChannel(fromTitles: sessionSlackTitles)
            ?? (slackRecorded ? inferSlackChannel(in: start, end: end, db: db) : nil)
        // Participant is "who the call was with": a Teams meeting subject, or —
        // for a 1:1 Slack huddle — the other person. Teams wins if both held the
        // mic. A 1:1 person only names the call when it wasn't a channel huddle
        // (a channel huddle is identified by its channel instead).
        let teamsParticipant = MicSession.parseTeamsParticipant(fromTitles: sessionTeamsTitles)
            ?? (teamsRecorded ? inferParticipant(in: start, end: end, db: db) : nil)
        let slackPerson = slackChannel == nil
            ? (MicSession.bestSlackHuddlePerson(fromTitles: sessionSlackTitles)
                ?? (slackRecorded ? inferSlackHuddlePerson(in: start, end: end, db: db) : nil))
            : nil
        let participant = teamsParticipant ?? slackPerson
        return (participant, slackChannel)
    }

    // MARK: - CoreAudio probe

    private func micIsRunningSomewhere() -> Bool {
        // Query every audio device that has an INPUT stream. The default-input
        // device alone isn't enough — Slack huddles in particular can hold the
        // mic open on a non-default device while macOS still shows the orange
        // dot. We OR the IsRunningSomewhere flag across all input-capable
        // devices and return true if any one of them is hot.
        for deviceID in allInputCapableAudioDevices() {
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
            if status == noErr, isRunning != 0 { return true }
        }
        return false
    }

    /// Returns every audio device on the system that has at least one input
    /// stream (i.e. could be acting as a microphone).
    private func allInputCapableAudioDevices() -> [AudioDeviceID] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &dataSize, &devices) == noErr else { return [] }

        return devices.filter { hasInputStreams($0) }
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize)
        return status == noErr && streamsSize > 0
    }

    private func defaultInputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Per-process audio attribution (macOS 14.2+)

    /// One process that's currently reading from an audio input device.
    struct Recorder: Hashable {
        let pid: pid_t
        /// PID of the user-facing owning app (the GUI process that owns the
        /// windows), resolved by walking the parent chain. Falls back to `pid`
        /// when no owner could be resolved. This is the PID to hand to the
        /// Accessibility API to read the call's window titles.
        let ownerPID: pid_t
        let bundleID: String?
        let appName: String?
    }

    /// Enumerates every process that CoreAudio reports is actively reading
    /// from an input device right now. This is the same signal that drives
    /// the orange-dot tap-through in the macOS menu bar.
    private func currentInputRecorders() -> [Recorder] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            MicDebug.log("MicMonitor: ProcessObjectList size status=\(sizeStatus) dataSize=\(dataSize)")
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &dataSize, &processes)
        guard getStatus == noErr else {
            MicDebug.log("MicMonitor: ProcessObjectList get status=\(getStatus)")
            return []
        }
        MicDebug.log("currentInputRecorders: scanning \(processes.count) procs")
        var recorders: [Recorder] = []
        for procObj in processes {
            let pid = processPID(procObj)
            let runIn = processIsRunningInput(procObj)
            let runAny = processIsRunning(procObj)
            let inputDevs = processInputDeviceIDs(procObj)
            let allDevs = processDeviceIDs(procObj)
            if runAny || runIn || !inputDevs.isEmpty || !allDevs.isEmpty {
                let bidPreview = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
                MicDebug.log("  pid=\(pid) bid=\(bidPreview) isRunning=\(runAny) isRunningInput=\(runIn) inputDevs=\(inputDevs) allDevs=\(allDevs)")
            }
            // Only treat a process as recording when `IsRunningInput` is true.
            // The looser `IsRunning + inputDevs` heuristic produced stale
            // signal during device release (an app stops recording but takes
            // a few seconds to free the device), which merged consecutive
            // calls into one session.
            guard runIn, pid > 0 else { continue }
            // Many apps capture audio in a helper subprocess (Slack, Teams,
            // Chrome, Zoom). NSRunningApplication only resolves GUI apps, so
            // we walk up the parent chain to find the owning .app.
            if let owner = Self.resolveOwningApp(forPID: pid) {
                recorders.append(Recorder(pid: pid,
                                          ownerPID: owner.processIdentifier,
                                          bundleID: owner.bundleIdentifier?.lowercased(),
                                          appName: owner.localizedName))
            } else {
                recorders.append(Recorder(pid: pid, ownerPID: pid, bundleID: nil, appName: "PID \(pid)"))
            }
        }
        return recorders
    }

    /// Walks up the parent-PID chain looking for the user-facing owning
    /// application. Audio capture often happens in a helper subprocess (Slack,
    /// Teams modulehost, Chrome helpers, Zoom etc.). Each helper may register
    /// as its own NSRunningApplication with `activationPolicy = .prohibited`
    /// and a sub-identifier bundle ID (e.g. `com.microsoft.teams2.modulehost`),
    /// so we don't want to stop at the first match — we want the regular
    /// (dock-visible) parent app.
    ///
    /// Strategy: walk up to maxDepth ancestors, remember the first resolvable
    /// `NSRunningApplication` we see, and prefer one whose activationPolicy is
    /// `.regular` (foreground app) or `.accessory` (menubar agent). Fall back
    /// to the first resolved one if no regular ancestor is found.
    static func resolveOwningApp(forPID pid: pid_t, maxDepth: Int = 8) -> NSRunningApplication? {
        var current = pid
        var firstResolved: NSRunningApplication?
        for _ in 0..<maxDepth {
            if let app = NSRunningApplication(processIdentifier: current) {
                if firstResolved == nil { firstResolved = app }
                if app.activationPolicy != .prohibited { return app }
            }
            let parent = parentPID(of: current)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return firstResolved
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        guard status == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    private func processIsRunning(_ procObj: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(procObj, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// IDs of input-capable devices that this process currently has open.
    private func processInputDeviceIDs(_ procObj: AudioObjectID) -> [AudioDeviceID] {
        return processDevicesForScope(procObj, scope: kAudioObjectPropertyScopeInput)
    }

    /// IDs of every device this process has open across all scopes (input/output/global).
    private func processDeviceIDs(_ procObj: AudioObjectID) -> [AudioDeviceID] {
        return processDevicesForScope(procObj, scope: kAudioObjectPropertyScopeGlobal)
    }

    private func processDevicesForScope(_ procObj: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(procObj, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(procObj, &address, 0, nil, &dataSize, &devices) == noErr else { return [] }
        return devices
    }

    private func processIsRunningInput(_ procObj: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(procObj, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func processPID(_ procObj: AudioObjectID) -> pid_t {
        var pid: pid_t = 0
        var size: UInt32 = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(procObj, &address, 0, nil, &size, &pid) == noErr else { return 0 }
        return pid
    }

    // MARK: - Fallback VoIP heuristic

    private func runningVoipBundleIDs() -> [String] {
        let running = NSWorkspace.shared.runningApplications
        var found: [String] = []
        for app in running {
            guard let bid = app.bundleIdentifier?.lowercased() else { continue }
            if Self.voipBundleIDs.keys.contains(where: { $0.lowercased() == bid }) {
                found.append(bid)
            }
        }
        return Array(Set(found)).sorted()
    }

    /// Fallback participant guess from frontmost-app samples during the session
    /// window, used only when the live AX read found no Teams window. Parsing
    /// is shared with the AX path via `MicSession.parseTeamsParticipant`.
    private func inferParticipant(in start: Date, end: Date, db: AppDatabase) -> String? {
        let teamsBundles: Set<String> = ["com.microsoft.teams", "com.microsoft.teams2"]
        guard let samples = try? db.samplesOverlapping(start: start, end: end) else { return nil }
        let titles = samples.compactMap { s -> String? in
            guard let bid = s.appBundleID?.lowercased(), teamsBundles.contains(bid) else { return nil }
            return s.windowTitle
        }
        return MicSession.parseTeamsParticipant(fromTitles: titles)
    }

    /// Fallback Slack channel guess from the frontmost Slack window titles
    /// captured in foreground samples during the session, used only when the
    /// live AX read found nothing. A huddle title (`Huddle: nfc-internal …`)
    /// pins the channel; falls back to the most-viewed channel window.
    private func inferSlackChannel(in start: Date, end: Date, db: AppDatabase) -> String? {
        guard let samples = try? db.samplesOverlapping(start: start, end: end) else { return nil }
        let titles = samples.compactMap { s -> String? in
            guard let bid = s.appBundleID?.lowercased(), bid.contains("slack") else { return nil }
            return s.windowTitle
        }
        return MicSession.bestSlackChannel(fromTitles: titles)
    }

    /// Fallback 1:1 Slack huddle counterpart from foreground samples, used only
    /// when the live AX read found nothing.
    private func inferSlackHuddlePerson(in start: Date, end: Date, db: AppDatabase) -> String? {
        guard let samples = try? db.samplesOverlapping(start: start, end: end) else { return nil }
        let titles = samples.compactMap { s -> String? in
            guard let bid = s.appBundleID?.lowercased(), bid.contains("slack") else { return nil }
            return s.windowTitle
        }
        return MicSession.bestSlackHuddlePerson(fromTitles: titles)
    }

    nonisolated static func displayName(forBundleID bid: String) -> String? {
        voipBundleIDs.first { $0.key.lowercased() == bid.lowercased() }?.value
    }
}
