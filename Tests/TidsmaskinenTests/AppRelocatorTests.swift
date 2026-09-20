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
            + "&& { chown \(getuid()):\(getgid()) '/Users/o'\\''brien/Applications'; "
            + "chmod u+rwx '/Users/o'\\''brien/Applications'; "
            + "chown -R \(getuid()):\(getgid()) '/Users/o'\\''brien/Applications/Tidsmaskinen.app' || true; }"
        )
    }

    func testMoveCommandOnlyChownsWhenAlreadyInPlace() {
        let target = URL(fileURLWithPath: "/Users/me/Applications/Tidsmaskinen.app")
        XCTAssertEqual(
            AppRelocator.moveCommand(from: target, to: target),
            "chown \(getuid()):\(getgid()) '/Users/me/Applications'; "
            + "chmod u+rwx '/Users/me/Applications'; "
            + "chown -R \(getuid()):\(getgid()) '/Users/me/Applications/Tidsmaskinen.app'"
        )
    }

    func testMoveCommandTakesOwnershipOfTheDestinationFolder() {
        // Sparkle checks the parent too, so a root-owned ~/Applications would
        // keep every update prompting even once the bundle itself is ours.
        let command = AppRelocator.moveCommand(
            from: URL(fileURLWithPath: "/Applications/Tidsmaskinen.app"),
            to: URL(fileURLWithPath: "/Users/me/Applications/Tidsmaskinen.app")
        )
        XCTAssertTrue(command.contains("chown \(getuid()):\(getgid()) '/Users/me/Applications'"),
                      "the destination folder must end up user-owned: \(command)")
        XCTAssertFalse(command.contains("chown -R \(getuid()):\(getgid()) '/Users/me/Applications'"),
                       "must not recurse into other apps living there: \(command)")
    }

    func testVersionComparisonIsNumericNotLexical() {
        // Lexical ordering would call 0.3.9 newer than 0.3.15 and let an older
        // copy overwrite the install the user actually keeps.
        XCTAssertTrue(AppRelocator.isNewer("0.3.15", than: "0.3.9"))
        XCTAssertFalse(AppRelocator.isNewer("0.3.9", than: "0.3.15"))
        XCTAssertTrue(AppRelocator.isNewer("0.4.0", than: "0.3.15"))
        XCTAssertFalse(AppRelocator.isNewer("0.3.15", than: "0.3.15"), "an equal version is not newer")
    }

    func testEmptyDestinationIsFreeToTake() {
        XCTAssertNil(AppRelocator.destinationRefusal(at: root.appendingPathComponent("Nothing.app"),
                                                     ourVersion: "1.0", ourBundleID: "se.forefront.tidsmaskinen"))
    }

    func testDestinationThatIsNotOurBundleIsNeverDeleted() throws {
        // Root is about to rm -rf this path, so a same-named folder that isn't
        // our app has to stop the move rather than be replaced.
        let stranger = try makeBundle(in: root)
        let refusal = AppRelocator.destinationRefusal(at: stranger, ourVersion: "1.0",
                                                      ourBundleID: "se.forefront.tidsmaskinen")
        XCTAssertEqual(refusal?.title, "Something else is already there")
    }

    func testNewerDestinationBlocksTheMove() throws {
        let bundle = try makeBundle(in: root)
        try writeInfoPlist(in: bundle, version: "0.3.15", bundleID: "se.forefront.tidsmaskinen")
        // 0.3.9 is the older copy here; a lexical compare would get this backwards.
        let refusal = AppRelocator.destinationRefusal(at: bundle, ourVersion: "0.3.9",
                                                      ourBundleID: "se.forefront.tidsmaskinen")
        XCTAssertEqual(refusal?.title, "A newer Tidsmaskinen is already installed")
    }

    func testOlderDestinationIsReplaceable() throws {
        let bundle = try makeBundle(in: root)
        try writeInfoPlist(in: bundle, version: "0.3.9", bundleID: "se.forefront.tidsmaskinen")
        XCTAssertNil(AppRelocator.destinationRefusal(at: bundle, ourVersion: "0.3.15",
                                                     ourBundleID: "se.forefront.tidsmaskinen"))
    }

    private func writeInfoPlist(in bundle: URL, version: String, bundleID: String) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID,
                                    "CFBundleVersion": version,
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
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
