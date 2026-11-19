import XCTest

/// One sign-in is acted on once, and the tabs can't be rebuilt in a spin
/// (SessionGate; on the M4 a sign-in rebuilt them 2,388 times in 80 s).
final class SessionGateTests: XCTestCase {
    func testASignInFromTheSheetIsActedOnOnce() {
        var gate = SessionGate()
        XCTAssertEqual(gate.proposed(path: ""), .proceed, "signed in, a page is a page")
        XCTAssertTrue(gate.refused())
        XCTAssertFalse(gate.refused(), "one wait at a time")
        XCTAssertEqual(gate.proposed(path: "/sign_in"), .proceed)
        XCTAssertEqual(gate.proposed(path: "/development_session"), .proceed)
        XCTAssertEqual(gate.proposed(path: "/refresh_historical_location"), .signedIn)
        // The rebuilt tabs' first visits, and Rails' refresh after a card is answered.
        XCTAssertEqual(gate.proposed(path: ""), .proceed)
        XCTAssertEqual(gate.proposed(path: "/"), .proceed)
        XCTAssertEqual(gate.proposed(path: "/refresh_historical_location"), .proceed)
        XCTAssertEqual(gate.phase, .signedIn)
    }

    func testTheBrowserSheetEndsTheWait() {
        var gate = SessionGate()
        _ = gate.refused()
        gate.signedInThroughBrowserSheet()
        XCTAssertEqual(gate.proposed(path: "/"), .proceed)
    }

    func testOnlyA401AsksToSignInAnyOtherFailureShowsTheError() {
        XCTAssertEqual(SessionGate.failed(statusCode: 401), .askToSignIn)
        XCTAssertEqual(SessionGate.failed(statusCode: nil), .showError, "refused, timed out, no such host")
        XCTAssertEqual(SessionGate.failed(statusCode: 500), .showError)
        XCTAssertEqual(SessionGate.failed(statusCode: 503), .showError)
        XCTAssertEqual(SessionGate.failed(statusCode: 404), .showError)
    }

    func testAFirstPageThatNeitherLoadsNorFailsIsOverdue() {
        var watch = FirstVisitWatch()
        let start = Date()
        let first = watch.started(at: start)
        XCTAssertFalse(watch.isOverdue(first, at: start.addingTimeInterval(FirstVisitWatch.patience - 1)))
        XCTAssertTrue(watch.isOverdue(first, at: start.addingTimeInterval(FirstVisitWatch.patience)), "a spinner forever: show the error")

        let second = watch.started(at: start)
        XCTAssertFalse(watch.isOverdue(first, at: start.addingTimeInterval(60)), "older tabs' wait never fires on newer ones")
        watch.settled()
        XCTAssertFalse(watch.isOverdue(second, at: start.addingTimeInterval(60)), "loaded or failed: nothing to show")
    }

    func testTheTabsAreNeverRebuiltTwiceWithinTheGap() {
        var gate = SessionGate()
        let start = Date()
        XCTAssertTrue(gate.mayRebuild(at: start))
        XCTAssertFalse(gate.mayRebuild(at: start.addingTimeInterval(0.035)))
        XCTAssertFalse(gate.mayRebuild(at: start.addingTimeInterval(SessionGate.minimumGap - 0.01)))
        XCTAssertTrue(gate.mayRebuild(at: start.addingTimeInterval(SessionGate.minimumGap)))
    }
}
