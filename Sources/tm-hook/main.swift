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
let payloadString: String = {
    guard !stdinData.isEmpty else { return "null" }
    // The hook delivers JSON via stdin; pass it through as-is.
    if let s = String(data: stdinData, encoding: .utf8) {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "null"
}()

let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let timestamp = isoFormatter.string(from: Date())

// Build a single-line JSON envelope: {"timestamp":"...","eventType":"...","payload":{...}}
let envelope = """
{"timestamp":"\(timestamp)","eventType":"\(escapeJSON(eventType))","payload":\(payloadString)}

"""

func escapeJSON(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\"":  out += "\\\""
        case "\\":  out += "\\\\"
        case "\n":  out += "\\n"
        case "\r":  out += "\\r"
        case "\t":  out += "\\t"
        default:    out.append(ch)
        }
    }
    return out
}

let fm = FileManager.default
guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true) else {
    exit(0)
}
let dir = appSupport.appendingPathComponent("Tidsmaskinen", isDirectory: true)
try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
let logURL = dir.appendingPathComponent("claude-events.jsonl")

if !fm.fileExists(atPath: logURL.path) {
    fm.createFile(atPath: logURL.path, contents: nil)
}

guard let handle = try? FileHandle(forWritingTo: logURL) else { exit(0) }
do {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(envelope.utf8))
    try handle.close()
} catch {
    // Silent failure — Claude Code must not see this.
}
