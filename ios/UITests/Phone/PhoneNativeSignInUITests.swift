import XCTest

/// Signs the phone's app in the way it does on a device: the web's sign-in
/// page offers "Sign in", which opens the browser sheet
/// (ASWebAuthenticationSession); the sheet signs in and comes back to the
/// app with a one-time code, and the app trades it for its session
/// (BUILD.md, "Signing in through the sheet"). Against the development
/// fixture the sheet's page offers the development sign-in, which hands the
/// app a code exactly as the provider's return would.
final class PhoneNativeSignInUITests: XCTestCase {
    /// The app forgets its cookies at launch with this (Debug builds only),
    /// so each run starts signed out.
    private static let signedOut = "-SignedOutForUITests"

    @MainActor
    func testSignInThroughTheSheetAndStaySignedIn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [Self.signedOut]
        app.launch()

        let signIn = element(beginningWith: "Sign in with", in: app)
        XCTAssertTrue(signIn.waitForExistence(timeout: 120), "the sign-in page should offer the sheet")
        XCTAssertFalse(element(containing: "Watch fixture", in: app).exists, "signed out to begin with")
        snap("phone-native-01-sign-in-page")
        signIn.tap()

        // iOS asks before the sheet opens: "… Wants to Use … to Sign In".
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Continue"]
        if allow.waitForExistence(timeout: 10) {
            snap("phone-native-02-permission")
            allow.tap()
        } else if app.buttons["Continue"].exists {
            snap("phone-native-02-permission")
            app.buttons["Continue"].tap()
        }

        // The sheet: Safari's own browser, showing the install's page. Its
        // contents may belong to the app's tree or to Safari's view service.
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        // The app's own sign-in page, behind the sheet, has the same button,
        // and a tap on it lands on empty sheet (seen on the M4). The sheet's
        // page sits in Safari's view service or, on the simulator, after the
        // app's page in the app's own tree: wait until it is there.
        let label = NSPredicate(format: "label CONTAINS %@", "Sign in as a local developer")
        let inSheet = sheet.descendants(matching: .any).matching(label)
        let inApp = app.descendants(matching: .any).matching(label)
        func sheetButton() -> XCUIElement? {
            if inSheet.count > 0 { return inSheet.element(boundBy: inSheet.count - 1) }
            if inApp.count > 1 { return inApp.element(boundBy: inApp.count - 1) }
            return nil
        }
        let deadline = Date().addingTimeInterval(60)
        while sheetButton().map({ !$0.isHittable }) ?? true, Date() < deadline { sleep(1) }
        // The button can be in the tree before the page has drawn, and a tap
        // then goes nowhere (seen on the M4): give the page a moment.
        sleep(2)
        snap("phone-native-03-sheet-open")
        try XCTUnwrap(sheetButton(), "the sheet should show the install's sign-in, with the development button").tap()

        let signedIn = element(containing: "Watch fixture", in: app)
        XCTAssertTrue(signedIn.waitForExistence(timeout: 90), "back in the app, signed in: the fixture's agent is listed")
        XCTAssertFalse(element(beginningWith: "Sign in with", in: app).exists)
        snap("phone-native-04-signed-in")

        // The session is the app's own cookie: it outlasts the app.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(signedIn.waitForExistence(timeout: 90), "still signed in after a relaunch")
        snap("phone-native-05-after-relaunch")
    }

    /// Signing out is the Settings tab's page, which also takes the Watch's
    /// token and this phone's notifications (BUILD.md): iOS's alert asks first,
    /// the page tells the app (SessionComponent), back to the sign-in sheet.
    @MainActor
    func testSignOut() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(element(containing: "Watch fixture", in: app).waitForExistence(timeout: 90), "signed in, from the sheet test")

        app.tabBars.buttons["Settings"].tap()
        let signOut = settingsSignOut(in: app)
        XCTAssertTrue(reveal(signOut, in: app), "the Settings page offers Sign out, at its foot")
        signOut.tap()
        let confirm = signOutConfirmation(in: app)
        XCTAssertTrue(confirm.exists, "Sign out asks first")
        confirm.tap()
        XCTAssertTrue(element(beginningWith: "Sign in with", in: app).waitForExistence(timeout: 60), "signed out: the sign-in sheet again")
        snap("phone-native-07-signed-out")
    }
}
