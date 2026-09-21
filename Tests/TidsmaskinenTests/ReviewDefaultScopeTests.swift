import XCTest
@testable import Tidsmaskinen

/// Review preselects a scope per unit type: Always where one pattern is one
/// customer for good, narrower where it serves several.
final class ReviewDefaultScopeTests: XCTestCase {
    private func session(participant: String? = nil, channel: String? = nil) -> MicSession {
        MicSession(id: "s", startedAt: Date(), endedAt: Date().addingTimeInterval(600), voipAppsCSV: "com.tinyspeck.slackmacgap",
                   participant: participant, slackChannel: channel, createdAt: Date(), updatedAt: Date())
    }

    func testRepoHostAndPathDefaultToAlways() {
        for kind: AppDatabase.SignalAggregate.Kind in [.gitRepoSlug, .urlHost, .urlPath] {
            let unit = ReviewUnit.signal(.init(kind: kind, value: "x", totalSeconds: 600))
            XCTAssertEqual(unit.defaultScope, .always, "\(kind)")
        }
    }

    func testAppDefaultsToThisWeek() {
        let unit = ReviewUnit.signal(.init(kind: .appBundleID, value: "com.figma.Desktop", totalSeconds: 600))
        XCTAssertEqual(unit.defaultScope, .thisWeek)
    }

    func testChannelHuddleDefaultsToAlwaysButPersonCallToJustThis() {
        XCTAssertEqual(ReviewUnit.call(session: session(channel: "nfc-internal"), seconds: 600).defaultScope, .always)
        XCTAssertEqual(ReviewUnit.call(session: session(participant: "Victor Vadelius"), seconds: 600).defaultScope, .justThis)
        XCTAssertEqual(ReviewUnit.call(session: session(participant: "Victor", channel: "nfc-internal"), seconds: 600).defaultScope, .always)
    }
}
