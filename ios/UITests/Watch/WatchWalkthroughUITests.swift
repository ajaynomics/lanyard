import XCTest

/// BUILD.md, "The walkthrough", on the Watch, with the phone's app signed in and running, and
/// the fixture's four cards waiting (script/watch_fixture.rb): the cards, then
/// an agent's thread and a reply from it. Each answer is
/// shown as done only once Rails confirms it. Run the fixture script again
/// before running this a second time: the answered cards are gone.
final class WatchWalkthroughUITests: XCTestCase {
    static let message = "Hello from the Watch"

    @MainActor
    func testWalkthrough() throws {
        continueAfterFailure = false
        let app = launch()
        snap("watch-01-launch")

        let parking = element(containing: "parking-spot", in: app)
        // The first run waits for the token: the Watch asks the phone, which asks Rails.
        XCTAssertTrue(reveal(parking, in: app, timeout: 120), "the list should load once the Watch has its token")
        snap("watch-03-list")
        parking.tap()
        answer("Allow once", expecting: "Allowed.", in: app, shots: ("watch-04-card", "watch-05-allowed"))

        relaunch(app)
        let wifi = element(containing: "old-wifi", in: app)
        XCTAssertTrue(reveal(wifi, in: app))
        wifi.tap()
        answer("Decline", expecting: "Declined.", in: app, shots: ("watch-06a-card", "watch-06-declined"))

        relaunch(app)
        let long = element(containing: "A long made-up instruction", in: app)
        XCTAssertTrue(reveal(long, in: app))
        long.tap()
        XCTAssertTrue(element(containing: "Allow this on your iPhone.", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Allow once"].exists, "a card too long for the Watch is never allowed from it")
        XCTAssertTrue(app.buttons["Decline"].exists)
        snap("watch-07-phone-only")

        relaunch(app)
        let agent = app.descendants(matching: .any)["agent:Watch fixture"]
        XCTAssertTrue(reveal(agent, in: app))
        agent.tap()
        // Its thread first, read from Rails, then Reply opens the composer.
        let reply = app.descendants(matching: .any)["reply"]
        XCTAssertTrue(reveal(reply, in: app, timeout: 30), "the thread should load with Reply at its foot")
        XCTAssertFalse(element(beginningWith: "Couldn't load", in: app).exists, "the thread should load from Rails")
        snap("watch-08a-thread")
        reply.tap()
        let send = app.buttons["Send"]
        XCTAssertTrue(reveal(send, in: app, timeout: 10))
        snap("watch-08b-compose")
        send.tap()
        XCTAssertTrue(element(beginningWith: "Accepted.", in: app).waitForExistence(timeout: 30), "the agent's server should accept it")
        snap("watch-08-accepted")
    }

    @MainActor private func answer(_ button: String, expecting confirmed: String, in app: XCUIApplication, shots: (String, String)) {
        let control = app.buttons[button]
        XCTAssertTrue(reveal(control, in: app, timeout: 10))
        snap(shots.0)
        control.tap()
        let done = app.staticTexts[confirmed]
        XCTAssertTrue(reveal(done, in: app, timeout: 30), "\(confirmed) appears only once Rails confirms")
        snap(shots.1)
    }
}

extension XCTestCase {
    /// The Watch app, with the compose box prefilled (a debug build only):
    /// typing on a Watch simulator from a UI test is not dependable.
    @MainActor func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LANYARD_UI_TEST_MESSAGE"] = WatchWalkthroughUITests.message
        app.launch()
        return app
    }

    @MainActor func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
    }
}
