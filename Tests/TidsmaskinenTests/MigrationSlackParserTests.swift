import XCTest
@testable import Tidsmaskinen

/// Call detection is gone, but migrations v13, v15, v16 and v21 still parse
/// Slack huddle titles when an existing database upgrades. These cases keep
/// those parsers from drifting and writing wrong channels into history.
final class MigrationSlackParserTests: XCTestCase {

    private func parse(_ t: String) -> (name: String, isChannel: Bool)? {
        MicSession.parseSlackHuddleTitle(fromTitle: t)
    }

    func testLegacyHuddleFormat() {
        XCTAssertEqual(parse("Huddle: nfc-internal – Forefront Ignite – Slack 🎤")?.name, "nfc-internal")
        XCTAssertEqual(parse("Huddle: nfc-internal – Forefront Ignite – Slack 🎤")?.isChannel, true)
        XCTAssertEqual(parse("Huddle: #ericsson-internal – Forefront Ignite – Slack")?.name, "ericsson-internal")
        XCTAssertEqual(parse("Huddle: @Victor Vadelius – Forefront Ignite – Slack 🎤")?.name, "Victor Vadelius")
        XCTAssertEqual(parse("Huddle: @Victor Vadelius – Forefront Ignite – Slack 🎤")?.isChannel, false)
    }

    func testCurrentHuddleFormat() {
        XCTAssertEqual(parse("Victor Vadelius - Forefront Ignite - Slack")?.name, "Victor Vadelius")
        XCTAssertEqual(parse("Victor Vadelius - Forefront Ignite - Slack")?.isChannel, false)
        XCTAssertEqual(parse("nfc-internal - Forefront Ignite - Slack")?.name, "nfc-internal")
        XCTAssertEqual(parse("nfc-internal - Forefront Ignite - Slack")?.isChannel, true)
    }

    func testNonHuddleWindowsIgnored() {
        // Main window: always carries (DM)/(Channel), and [Main] while a huddle
        // window exists. Neither is the huddle.
        XCTAssertNil(parse("Jonas Roslin (DM) - Forefront Ignite - Slack"))
        XCTAssertNil(parse("skistar-internal (Channel) - Forefront Ignite - 1 new item - Slack [Main] 🏠🔊"))
        XCTAssertNil(parse("Signal - Forefront Ignite - 2 new items - Slack"))
        XCTAssertNil(parse("Threads - Forefront Ignite - Slack"))
        XCTAssertNil(parse("- Forefront Ignite - Slack"))
        XCTAssertNil(parse("Some Doc - Google Chrome"))
    }

    func testBestOfSessionPrefersFrequency() {
        let titles = [
            "app-vantage (Channel) - Forefront Ignite - 3 new items - Slack [Main] 🏠🔊",
            "Victor Vadelius - Forefront Ignite - Slack",
            "Victor Vadelius - Forefront Ignite - Slack",
            "Threads - Forefront Ignite - Slack"
        ]
        XCTAssertEqual(MicSession.bestSlackHuddlePerson(fromTitles: titles), "Victor Vadelius")
        // A channel merely navigated to in the main window is not the channel.
        XCTAssertNil(MicSession.bestSlackChannel(fromTitles: titles))
    }
}
