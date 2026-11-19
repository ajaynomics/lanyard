import XCTest

/// Signs the phone's app in through the web app's own development sign-in,
/// in its web view (BUILD.md, "The walkthrough"): the quick way for the
/// fixture. A device signs in through the sheet (PhoneNativeSignInUITests).
/// The session stays in WebKit's cookies on the phone.
final class PhoneSignInUITests: XCTestCase {
    @MainActor
    func testSignInAsLocalDeveloper() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        // The fixture's agent is on the first page once signed in.
        let signedIn = element(containing: "Watch fixture", in: app)
        // A development server's first page can take a while (assets compile on
        // first request), so wait long; and find the button by its label, as
        // a web view's elements have no identifiers.
        if !signedIn.waitForExistence(timeout: 20) {
            let signIn = element(containing: "Sign in as a local developer", in: app)
            XCTAssertTrue(signIn.waitForExistence(timeout: 120), "the web sign-in page should show its development button")
            snap("phone-01-sign-in")
            signIn.tap()
        }
        XCTAssertTrue(signedIn.waitForExistence(timeout: 90), "the signed-in page should list the Watch fixture agent")
        snap("phone-02-signed-in")
    }
}
