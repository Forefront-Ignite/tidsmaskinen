import XCTest
@testable import Tidsmaskinen

final class HookInstallerTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("hooks.json"))
    }

    func testCodexInstallRefreshAndUninstallPreserveOtherHooks() throws {
        try withFile { url in
            let original = #"{"description":"Personal hooks","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/usr/local/bin/my-tm-hook-test.sh"},{"type":"command","command":"/old/tm-hook --provider codex Stop"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"echo check"}]}]}}"#
            try Data(original.utf8).write(to: url)
            let path = "/Applications/Niklas's Apps/Tidsmaskinen.app/Contents/MacOS/tm-hook"
            try HookInstaller.install(provider: .codex, fileURL: url, executablePath: path)
            let first = try Data(contentsOf: url)
            try HookInstaller.install(provider: .codex, fileURL: url, executablePath: path)
            XCTAssertEqual(try Data(contentsOf: url), first, "Installation must be idempotent")
            XCTAssertEqual(HookInstaller.currentState(provider: .codex, fileURL: url, executablePath: path), .installed(path: path))
            XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("tm-backup"), encoding: .utf8), original)
            try HookInstaller.uninstall(provider: .codex, fileURL: url)
            let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(settings["description"] as? String, "Personal hooks")
            let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])
            XCTAssertEqual(Set(hooks.keys), ["Stop", "PreToolUse"])
            let stop = try XCTUnwrap(hooks["Stop"]?.first?["hooks"] as? [[String: Any]])
            XCTAssertEqual(stop.count, 1)
            XCTAssertEqual(stop[0]["command"] as? String, "/usr/local/bin/my-tm-hook-test.sh")
        }
    }

    func testIncompleteInstallationNeedsRefresh() throws {
        try withFile { url in
            let partial = #"{"hooks":{"SessionStart":[{"hooks":[{"command":"/app/tm-hook --provider codex SessionStart"}]}]}}"#
            try Data(partial.utf8).write(to: url)
            XCTAssertEqual(HookInstaller.currentState(provider: .codex, fileURL: url, executablePath: "/app/tm-hook"),
                           .stale(installedPath: "/app/tm-hook", expectedPath: "/app/tm-hook"))
        }
    }

    /// The relocation flow relies on this: after AppRelocator moves the bundle,
    /// hooks still name the old absolute tm-hook path, and reinstalling must
    /// repoint them rather than leave a second, dead entry behind.
    func testReinstallRepointsHooksAfterTheBundleMoves() throws {
        try withFile { url in
            let old = "/Applications/Tidsmaskinen.app/Contents/MacOS/tm-hook"
            let new = "/Users/me/Applications/Tidsmaskinen.app/Contents/MacOS/tm-hook"
            try HookInstaller.install(provider: .claude, fileURL: url, executablePath: old)
            XCTAssertEqual(HookInstaller.currentState(provider: .claude, fileURL: url, executablePath: new),
                           .stale(installedPath: old, expectedPath: new))

            try HookInstaller.install(provider: .claude, fileURL: url, executablePath: new)
            XCTAssertEqual(HookInstaller.currentState(provider: .claude, fileURL: url, executablePath: new),
                           .installed(path: new))
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(old), "the dead path must be gone, not merely joined by the new one")
        }
    }

    func testMalformedConfigurationIsNeverOverwritten() throws {
        for input in ["{", "[]", #"{"hooks":true}"#, #"{"hooks":{"Stop":[{"hooks":"bad"}]}}"#] {
            try withFile { url in
                let data = Data(input.utf8)
                try data.write(to: url)
                XCTAssertThrowsError(try HookInstaller.install(provider: .codex, fileURL: url, executablePath: "/app/tm-hook"))
                XCTAssertThrowsError(try HookInstaller.uninstall(provider: .codex, fileURL: url))
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    func testLegacyClaudeHookRefreshPreservesSettings() throws {
        try withFile { url in
            try Data(#"{"model":"opus","hooks":{"Stop":[{"command":"/old/tm-hook Stop"}]}}"#.utf8).write(to: url)
            let path = "/Applications/Tidsmaskinen.app/Contents/MacOS/tm-hook"
            try HookInstaller.install(fileURL: url, executablePath: path)
            XCTAssertEqual(HookInstaller.currentState(fileURL: url, executablePath: path), .installed(path: path))
            try HookInstaller.uninstall(fileURL: url)
            let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
            XCTAssertEqual(settings, ["model": "opus"])
        }
    }
}
