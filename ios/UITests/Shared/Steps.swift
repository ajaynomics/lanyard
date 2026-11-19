import XCTest

// What both UI test bundles share: a named screenshot for each step, kept in
// the result bundle (BUILD.md, "Screenshots"), and finding things by their words.
extension XCTestCase {
    @MainActor func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func element(beginningWith text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// The Settings page's Sign out, a button in the web view (settings/_native_rows).
    @MainActor func settingsSignOut(in app: XCUIApplication) -> XCUIElement {
        app.webViews.buttons["Sign out"]
    }

    /// The "Sign out" confirmation: iOS's own alert (Bridge Components'
    /// alert, from the page's data-turbo-confirm). Never the page's button of
    /// the same name, which is in the web view.
    @MainActor func signOutConfirmation(in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let confirm = app.alerts.buttons["Sign out"]
        _ = confirm.waitForExistence(timeout: timeout)
        return confirm
    }

    /// Waits for an element and scrolls until it can be tapped: a list's
    /// rows below the screen may not exist until scrolled to.
    @MainActor func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 45) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.waitForExistence(timeout: 2), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
