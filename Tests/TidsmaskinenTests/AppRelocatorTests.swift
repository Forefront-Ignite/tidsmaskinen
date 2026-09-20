import XCTest
@testable import Tidsmaskinen

@MainActor
final class AppRelocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRelocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(in parent: URL) throws -> URL {
        let bundle = parent.appendingPathComponent("Tidsmaskinen.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    func testUserOwnedBundleInWritableFolderNeedsNoAdmin() throws {
        let bundle = try makeBundle(in: root)
        XCTAssertFalse(AppRelocator.updatesNeedAdmin(bundle))
    }

    // access(W_OK) ignores mode bits for root, so this would fail under sudo;
    // CI runs as the `runner` user.
    func testReadOnlyParentNeedsAdmin() throws {
        // Same shape as /Applications for a standard user: the bundle is ours
        // but the folder around it can't be written.
        let bundle = try makeBundle(in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertTrue(AppRelocator.updatesNeedAdmin(bundle))
    }

    func testMissingBundleNeedsAdmin() {
        XCTAssertTrue(AppRelocator.updatesNeedAdmin(root.appendingPathComponent("Missing.app")))
    }

    func testMoveCommandMovesThenChownsQuotedPaths() {
        let source = URL(fileURLWithPath: "/Applications/Tidsmaskinen.app")
        let target = URL(fileURLWithPath: "/Users/o'brien/Applications/Tidsmaskinen.app")
        let command = AppRelocator.moveCommand(from: source, to: target)
        XCTAssertEqual(
            command,
            "rm -rf '/Users/o'\\''brien/Applications/Tidsmaskinen.app' "
            + "&& mv -f '/Applications/Tidsmaskinen.app' '/Users/o'\\''brien/Applications/Tidsmaskinen.app' "
            + "&& { chown -R \(getuid()):\(getgid()) '/Users/o'\\''brien/Applications/Tidsmaskinen.app' || true; }"
        )
    }

    func testMoveCommandOnlyChownsWhenAlreadyInPlace() {
        let target = URL(fileURLWithPath: "/Users/me/Applications/Tidsmaskinen.app")
        XCTAssertEqual(
            AppRelocator.moveCommand(from: target, to: target),
            "chown -R \(getuid()):\(getgid()) '/Users/me/Applications/Tidsmaskinen.app'"
        )
    }

    func testAdminScriptEscapesShellCommandForAppleScript() {
        let path = "/Users/a'b\"c\\d ü/Tidsmaskinen.app"
        let command = "chown -R 1:2 \(AppRelocator.shellQuoted(path))"
        XCTAssertEqual(
            AppRelocator.adminScriptSource(for: command),
            """
            with timeout of 3600 seconds
                do shell script "chown -R 1:2 '/Users/a'\\\\''b\\"c\\\\d ü/Tidsmaskinen.app'" with administrator privileges
            end timeout
            """
        )
    }
}
