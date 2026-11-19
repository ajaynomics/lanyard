import XCTest

/// Tapping a notice killed the phone app (TestFlight, 2026-11-16). Here iOS
/// itself launches the killed app from a notice's banner and calls its
/// notification delegate, as it does for a tap on Apple's push: the app must
/// still be running, with the notice's page in its tab. The notice is a local
/// one the Debug build schedules when asked (NoticeTapFixture), not Apple's
/// push, and this is the simulator's Debug build, not TestFlight's Release.
/// Needs notifications allowed, so a fresh install or one that allowed them
/// (PhoneNotificationsUITests refuses them), and the development fixture
/// signed in (BUILD.md, "A tapped notice").
final class PhoneNoticeTapUITests: XCTestCase {
    @MainActor
    func testTappingANoticeLaunchesTheKilledAppToItsPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Signed in first: the cookies outlive the app.
        app.launchArguments = ["-SignedOutForUITests"]
        app.launch()
        let developer = element(containing: "Sign in as a local developer", in: app)
        XCTAssertTrue(developer.waitForExistence(timeout: 120), "signed out, the sign-in sheet should show")
        sleep(1)
        developer.tap()
        XCTAssertTrue(element(containing: "Watch fixture", in: app).waitForExistence(timeout: 90), "signed in")

        // The notice is scheduled; the app is killed before it shows.
        app.launchArguments = ["-NoticeTapForUITests", "/approvals"]
        app.launch()
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }
        sleep(2)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)

        // iOS launches it from the banner.
        let banner = element(containing: "Notice tap fixture", in: springboard)
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "the notice shows; if not, notifications are not allowed for the app")
        snap("phone-notice-tap-01-banner")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the tap launched the app")
        let needsYou = app.tabBars.buttons["Needs you"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 60))
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: needsYou)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 30), .completed, "the notice's page opened in Needs you")
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "still running after the tap")
        snap("phone-notice-tap-02-opened")
    }
}
