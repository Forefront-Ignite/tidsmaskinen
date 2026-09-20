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

    func testRemoveCommandOnlyTouchesTheOldCopy() {
        // The privileged step is now a single delete inside root-owned
        // /Applications, which nothing running as the user can swap. Anything
        // reaching into the home folder here would reopen that race.
        let command = AppRelocator.removeCommand(
            for: URL(fileURLWithPath: "/Applications/Niklas's Apps/Tidsmaskinen.app"))
        XCTAssertEqual(command, "rm -rf '/Applications/Niklas'\\''s Apps/Tidsmaskinen.app'")
        XCTAssertFalse(command.contains("chown"), command)
        XCTAssertFalse(command.contains("mv "), command)
    }

    func testOnlyTheSystemApplicationsFolderEarnsAnElevatedDelete() {
        // /Applications is root:admin, so its entries can't be swapped by
        // anything running as the user. Elevating for a path the user controls
        // would hand root a target they can redirect.
        XCTAssertTrue(AppRelocator.isInSystemApplications(
            URL(fileURLWithPath: "/Applications/Tidsmaskinen.app")))
        XCTAssertTrue(AppRelocator.isInSystemApplications(
            URL(fileURLWithPath: "/Applications/Utilities/Tidsmaskinen.app")))
        XCTAssertFalse(AppRelocator.isInSystemApplications(
            URL(fileURLWithPath: "/Users/me/Applications/Tidsmaskinen.app")))
        XCTAssertFalse(AppRelocator.isInSystemApplications(
            URL(fileURLWithPath: "/Users/me/Downloads/locked/Tidsmaskinen.app")))
        XCTAssertFalse(AppRelocator.isInSystemApplications(
            URL(fileURLWithPath: "/Applications")), "the folder itself is not an install")
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
                                                      ourBundleID: "se.forefront.tidsmaskinen",
                                                      isSignedLikeUs: { _ in true })
        XCTAssertEqual(refusal?.title, "Something else is already there")
    }

    func testNewerDestinationBlocksTheMove() throws {
        let bundle = try makeBundle(in: root)
        try writeInfoPlist(in: bundle, version: "0.3.15", bundleID: "se.forefront.tidsmaskinen")
        // 0.3.9 is the older copy here; a lexical compare would get this backwards.
        let refusal = AppRelocator.destinationRefusal(at: bundle, ourVersion: "0.3.9",
                                                      ourBundleID: "se.forefront.tidsmaskinen",
                                                      isSignedLikeUs: { _ in true })
        XCTAssertEqual(refusal?.title, "A newer Tidsmaskinen is already installed")
    }

    func testOlderDestinationIsReplaceable() throws {
        let bundle = try makeBundle(in: root)
        try writeInfoPlist(in: bundle, version: "0.3.9", bundleID: "se.forefront.tidsmaskinen")
        XCTAssertNil(AppRelocator.destinationRefusal(at: bundle, ourVersion: "0.3.15",
                                                     ourBundleID: "se.forefront.tidsmaskinen",
                                                     isSignedLikeUs: { _ in true }))
    }

    func testDestinationClaimingOurIdentifierWithoutOurSignatureIsRefused() throws {
        // CFBundleIdentifier is just a string any bundle can copy, and root is
        // about to rm -rf this path.
        let impostor = try makeBundle(in: root)
        try writeInfoPlist(in: impostor, version: "0.0.1", bundleID: "se.forefront.tidsmaskinen")
        let refusal = AppRelocator.destinationRefusal(at: impostor, ourVersion: "1.0",
                                                      ourBundleID: "se.forefront.tidsmaskinen",
                                                      isSignedLikeUs: { _ in false })
        XCTAssertEqual(refusal?.title, "That copy can't be verified")
    }

    func testUnsignedDirectoryDoesNotPassTheRealSignatureCheck() throws {
        XCTAssertFalse(AppRelocator.signedLikeUs(try makeBundle(in: root)))
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
