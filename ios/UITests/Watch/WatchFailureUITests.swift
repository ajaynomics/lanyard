import XCTest

/// What the Watch does when something is missing, each run on its own with
/// the condition set up first by the operator (BUILD.md, "Failures"). These
/// are simulations, and none may ever show success that Rails did not confirm.
final class WatchFailureUITests: XCTestCase {
    /// The phone's app is not running. The Watch has its token, so it loads
    /// the list from Rails directly: the phone carries nothing.
    @MainActor
    func testListLoadsWithoutThePhoneApp() throws {
        let app = launch()
        let agent = app.descendants(matching: .any)["agent:Watch fixture"]
        XCTAssertTrue(reveal(agent, in: app), "the list loads from Rails with the Watch's own token")
        snap("watch-09-without-the-phone-app")
    }

    /// The SSH forward is stopped, so the Watch cannot reach Rails.
    @MainActor
    func testServerUnreachable() throws {
        let app = launch()
        XCTAssertTrue(element(containing: "Couldn't load.", in: app).waitForExistence(timeout: 60), "the list fails, plainly")
        XCTAssertFalse(element(containing: "parking-spot", in: app).exists)
        snap("watch-10-server-unreachable")
    }

    /// A card open on the Watch is answered on the web meanwhile
    /// (bin/answer-elsewhere, started when this test logs READY). Allowing it
    /// from the Watch afterwards is refused, never shown as allowed.
    @MainActor
    func testAnsweredElsewhere() throws {
        continueAfterFailure = false
        let app = launch()
        let card = element(containing: "Answer in one short sentence.", in: app)
        XCTAssertTrue(reveal(card, in: app), "the every-time card should be waiting; run the fixture script again if not")
        card.tap()
        let allow = app.buttons["Allow once"]
        XCTAssertTrue(reveal(allow, in: app, timeout: 10))
        snap("watch-11a-card-open")

        XCTContext.runActivity(named: "READY: answer the card elsewhere now") { _ in
            Thread.sleep(forTimeInterval: 30)
        }

        allow.tap()
        let refused = element(beginningWith: "Already answered", in: app)
        XCTAssertTrue(reveal(refused, in: app, timeout: 30), "a card answered elsewhere is refused")
        XCTAssertFalse(app.staticTexts["Allowed."].exists)
        snap("watch-11-answered-elsewhere")
    }

    /// The Watch's token was revoked and the phone's app is not running: the
    /// Watch shows nothing from Rails and asks to reconnect. Then, once this
    /// test logs READY, the operator opens the phone's app, which hands over a
    /// new token, and the list loads again.
    @MainActor
    func testRevokedTokenReconnectsThroughThePhone() throws {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(element(containing: "Open Lanyard on your iPhone to reconnect.", in: app).waitForExistence(timeout: 30),
                      "a refused token is said plainly")
        XCTAssertFalse(app.descendants(matching: .any)["agent:Watch fixture"].exists)
        snap("watch-12-revoked")

        XCTContext.runActivity(named: "READY: open the iPhone app now") { _ in }
        let agent = app.descendants(matching: .any)["agent:Watch fixture"]
        XCTAssertTrue(reveal(agent, in: app, timeout: 120), "a new token arrives from the phone and the list loads")
        snap("watch-13-reconnected")
    }
}
