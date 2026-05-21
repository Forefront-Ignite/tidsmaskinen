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

    private static let voipBundleIDs: [String: String] = [
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
            try? database.endMicSession(id: id, endedAt: end, participant: nil, voipApps: finalApps)
            let s = MicSession(id: id, startedAt: start, endedAt: end,
                               voipAppsCSV: finalApps.isEmpty ? nil : finalApps.joined(separator: ","),
                               participant: nil,
                               customerID: nil, projectID: nil,
                               createdAt: start, updatedAt: end)
            onSessionEnd?(s)
        }
        currentSessionID = nil
        currentSessionStart = nil
        currentSessionRecorderBundles = []
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
        do {
            let id = try db.startMicSession(at: start, voipApps: apps)
            currentSessionID = id
            currentSessionStart = start
            let s = MicSession(id: id, startedAt: start, endedAt: nil,
                               voipAppsCSV: apps.isEmpty ? nil : apps.joined(separator: ","),
                               participant: nil, customerID: nil, projectID: nil,
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
        let participant = inferParticipant(in: start, end: end, db: db)
        let finalApps = Array(currentSessionRecorderBundles).sorted()
        do {
            try db.endMicSession(id: id, endedAt: end, participant: participant, voipApps: finalApps)
            let s = MicSession(id: id, startedAt: start, endedAt: end,
                               voipAppsCSV: finalApps.isEmpty ? nil : finalApps.joined(separator: ","),
                               participant: participant, customerID: nil, projectID: nil,
                               createdAt: start, updatedAt: end)
            onSessionEnd?(s)
        } catch {
            MicDebug.log("MicMonitor: failed to end session: \(error)")
        }
        currentSessionID = nil
        currentSessionStart = nil
        currentSessionRecorderBundles = []
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
                                          bundleID: owner.bundleIdentifier?.lowercased(),
                                          appName: owner.localizedName))
            } else {
                recorders.append(Recorder(pid: pid, bundleID: nil, appName: "PID \(pid)"))
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

    /// Best-effort participant guess from frontmost-app samples during the
    /// session window. We look at Teams window titles (they typically contain
    /// `<Name> | <Org> | <email> | Microsoft Teams`) and extract the first
    /// non-Chat segment.
    private func inferParticipant(in start: Date, end: Date, db: AppDatabase) -> String? {
        let teamsBundles: Set<String> = ["com.microsoft.teams", "com.microsoft.teams2"]
        guard let samples = try? db.samplesOverlapping(start: start, end: end) else { return nil }
        var counts: [String: Int] = [:]
        for s in samples {
            guard let bid = s.appBundleID?.lowercased(), teamsBundles.contains(bid),
                  let title = s.windowTitle else { continue }
            let parts = title.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            for p in parts {
                let lower = p.lowercased()
                if lower == "chat" || lower == "microsoft teams" { continue }
                if p.contains("@") { continue }
                if p.isEmpty { continue }
                counts[p, default: 0] += 1
                break
            }
        }
        return counts.max { $0.value < $1.value }.map { $0.key }
    }

    static func displayName(forBundleID bid: String) -> String? {
        voipBundleIDs.first { $0.key.lowercased() == bid.lowercased() }?.value
    }
}
