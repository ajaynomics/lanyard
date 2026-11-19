import XCTest

/// Settings' Notifications row says this iPhone's status, as its page does:
/// Not set up, then Off once iOS is refused, the Settings page beneath
/// following Rails' refresh while the sheet is up. Before, it said nothing. Needs
/// a fresh install (iOS asks only once) and Rails with APNs settings, or the
/// page offers no Turn on (tmp/native-notif/MAC-STEPS.md).
final class PhoneNotificationsUITests: XCTestCase {
    @MainActor
    func testRefusedNotificationsRowSaysOff() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SignedOutForUITests"]
        app.launch()
        let developer = element(containing: "Sign in as a local developer", in: app)
        XCTAssertTrue(developer.waitForExistence(timeout: 120), "signed out, the sign-in sheet should show")
        sleep(1)
        developer.tap()
        XCTAssertTrue(element(containing: "Watch fixture", in: app).waitForExistence(timeout: 90), "signed in")

        app.tabBars.buttons["Settings"].tap()
        let row = app.webViews.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Settings lists Notifications")
        XCTAssertTrue(app.webViews.staticTexts["Not set up"].waitForExistence(timeout: 30), "no token from this iPhone yet")
        snap("phone-notifications-01-not-set-up")

        // Turn on, on its page; iOS asks, and is refused.
        row.tap()
        let turnOn = app.webViews.buttons["Turn on"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 30), "the page offers Turn on")
        turnOn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let refuse = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        XCTAssertTrue(refuse.waitForExistence(timeout: 30), "iOS asks to allow notifications")
        snap("phone-notifications-02-ios-asks")
        refuse.tap()
        XCTAssertTrue(element(containing: "didn't turn notifications on", in: app).waitForExistence(timeout: 30), "the page says so")
        app.navigationBars.buttons["sheet-done"].tap()

        // The page beneath has already heard: the row says Off, and opens iOS's Settings.
        XCTAssertTrue(app.webViews.staticTexts["Off"].waitForExistence(timeout: 30), "refused: the row says Off")
        snap("phone-notifications-03-off")
    }
}
