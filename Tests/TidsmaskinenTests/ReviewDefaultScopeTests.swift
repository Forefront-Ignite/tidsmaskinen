import XCTest
@testable import Tidsmaskinen

/// Review preselects a scope per unit type: Always where one pattern is one
/// customer for good, narrower where it serves several.
final class ReviewDefaultScopeTests: XCTestCase {
    func testRepoHostAndPathDefaultToAlways() {
        for kind: AppDatabase.SignalAggregate.Kind in [.gitRepoSlug, .urlHost, .urlPath] {
            let unit = ReviewUnit.signal(.init(kind: kind, value: "x", totalSeconds: 600))
            XCTAssertEqual(unit.defaultScope, .always, "\(kind)")
        }
    }

    func testSessionsAndDoubleBookingsArePinnedOneByOne() {
        let session = ClaudeSession(id: "s", cwd: "/x", transcriptPath: nil, gitRepoPath: nil, gitRemoteURL: nil,
                                    startedAt: Date(), endedAt: nil, lastActivityAt: nil, activeSeconds: 0,
                                    promptCount: 0, customerID: nil, projectID: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(ReviewUnit.agentSession(session: session, seconds: 600).defaultScope, .justThis)
    }

    func testAppDefaultsToThisWeek() {
        let unit = ReviewUnit.signal(.init(kind: .appBundleID, value: "com.figma.Desktop", totalSeconds: 600))
        XCTAssertEqual(unit.defaultScope, .thisWeek)
    }

}
