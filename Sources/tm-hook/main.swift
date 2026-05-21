import Foundation

// Escape hatch: when Tidsmaskinen itself invokes `claude -p` (e.g. for AI
// suggestions) it sets TM_SKIP_HOOKS=1 so those internal sessions don't
// pollute the captured session list.
if ProcessInfo.processInfo.environment["TM_SKIP_HOOKS"] == "1" {
    exit(0)
}

// tm-hook — tiny Swift CLI invoked by Claude Code hooks.
// Reads JSON payload from stdin, appends one structured line to
// ~/Library/Application Support/Tidsmaskinen/claude-events.jsonl
// where the Tidsmaskinen menu-bar app tails it via FSEvents.
//
// Usage from ~/.claude/settings.json:
//   "SessionStart": [{ "command": "/path/to/Tidsmaskinen.app/Contents/MacOS/tm-hook SessionStart" }]
//
// Exits silently on errors — a misbehaving hook must never break Claude Code.

let args = CommandLine.arguments
let eventType = args.count > 1 ? args[1] : "Unknown"

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// Decode the incoming payload as JSON. If it isn't valid JSON, drop it on
// the floor (better than corrupting the JSONL log with a forged line).
let payloadObject: Any
if stdinData.isEmpty {
    payloadObject = NSNull()
} else if let parsed = try? JSONSerialization.jsonObject(with: stdinData,
                                                          options: [.fragmentsAllowed]) {
    payloadObject = parsed
} else {
    exit(0)
}

let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let timestamp = isoFormatter.string(from: Date())

let envelope: [String: Any] = [
    "timestamp": timestamp,
    "eventType": eventType,
    "payload": payloadObject
]

// Use .sortedKeys so the output is deterministic; pad with a single trailing
// newline so this is one JSONL line.
guard var envelopeData = try? JSONSerialization.data(withJSONObject: envelope,
                                                      options: [.sortedKeys]) else {
    exit(0)
}
envelopeData.append(0x0A)  // '\n'

let fm = FileManager.default
guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true) else {
    exit(0)
}
let dir = appSupport.appendingPathComponent("Tidsmaskinen", isDirectory: true)
try? fm.createDirectory(at: dir,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
let logURL = dir.appendingPathComponent("claude-events.jsonl")

if !fm.fileExists(atPath: logURL.path) {
    fm.createFile(atPath: logURL.path,
                  contents: nil,
                  attributes: [.posixPermissions: 0o600])
} else {
    // Belt-and-braces: tighten perms if a previous build created the file
    // with the default umask.
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
}

// Open with O_APPEND so concurrent writes from parallel Claude sessions don't
// stomp on each other. POSIX guarantees atomic append for writes up to
// PIPE_BUF (≥ 512 bytes on macOS); our envelopes can exceed that, but
// O_APPEND still gives us "writes don't overlap" because the kernel updates
// the file offset to EOF on each write.
let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
if fd < 0 { exit(0) }
defer { close(fd) }
_ = envelopeData.withUnsafeBytes { buf -> ssize_t in
    guard let base = buf.baseAddress else { return 0 }
    return write(fd, base, buf.count)
}
