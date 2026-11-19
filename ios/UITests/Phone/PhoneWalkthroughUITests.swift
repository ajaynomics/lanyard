import XCTest

/// The phone app as a native app, in light and dark (BUILD.md, "The phone
/// app's walkthrough"): signing in in its sheet, each tab, a thread, a form
/// as a sheet, a waiting card with Allow and Deny in its toolbar, the toast
/// its answer gives, native Settings, signing out, and the screen the app
/// shows when the server is out of reach. Each step keeps a screenshot named
/// phone-walk-<appearance>-NN-<step>. Against the development fixture (run
/// script/watch_fixture.rb first: each run denies one waiting card).
final class PhoneWalkthroughUITests: XCTestCase {
    @MainActor func testWalkthroughLight() throws { try walk(.light, named: "light") }
    @MainActor func testWalkthroughDark() throws { try walk(.dark, named: "dark") }

    @MainActor
    private func walk(_ appearance: XCUIDevice.Appearance, named look: String) throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = appearance
        defer { XCUIDevice.shared.appearance = .light }
        func shot(_ step: String) { snap("phone-walk-\(look)-\(step)") }

        // Signed out to begin with (a Debug-only launch argument clears the
        // cookies): the first page's 401 brings up the sign-in sheet.
        let app = XCUIApplication()
        app.launchArguments = ["-SignedOutForUITests", "-LanyardAppearance", look]
        app.launch()
        let developer = element(containing: "Sign in as a local developer", in: app)
        XCTAssertTrue(developer.waitForExistence(timeout: 120), "signed out, the sign-in sheet should show")
        sleep(1)
        shot("01-sign-in")
        developer.tap()

        // Agents, the first tab: the fixture's agent.
        let agent = element(containing: "Watch fixture", in: app)
        XCTAssertTrue(agent.waitForExistence(timeout: 90), "signed in, Agents lists the fixture's agent")
        XCTAssertTrue(app.tabBars.buttons["Agents"].exists && app.tabBars.buttons["Needs you"].exists && app.tabBars.buttons["Settings"].exists,
                      "three native tabs")
        XCTAssertFalse(element(containing: "Sign in with", in: app).exists)
        shot("02-agents")

        // A thread, pushed, its title in the bar and its actions the bar's menu.
        agent.tap()
        XCTAssertTrue(app.navigationBars["Watch fixture"].waitForExistence(timeout: 30), "the thread's title is the bar's")
        sleep(2)
        shot("03-conversation")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // New agent, the list's bar button, opens its form as a sheet.
        let newAgent = app.navigationBars.buttons["New agent"]
        XCTAssertTrue(newAgent.waitForExistence(timeout: 30), "New agent is a button in the bar")
        newAgent.tap()
        // A form's sheet: Cancel at the leading edge, its submit on the right.
        let cancel = app.navigationBars.buttons["sheet-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "the form opens as a sheet with Cancel")
        XCTAssertEqual(cancel.label, "Cancel")
        sleep(2)
        shot("04-sheet")
        cancel.tap()
        XCTAssertTrue(newAgent.waitForExistence(timeout: 10), "Cancel closes the sheet")

        // Needs you: the waiting cards, the count on the tab.
        app.tabBars.buttons["Needs you"].tap()
        let card = element(containing: "Allow forget note", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Needs you lists the fixture's cards")
        sleep(1)
        shot("05-needs-you")

        // A card alone, in a sheet, Allow and Deny in its toolbar.
        card.tap()
        // iOS 26 draws a toolbar's items as floating buttons, not inside a bar
        // the accessibility tree calls a toolbar: found by their identifiers.
        let deny = app.buttons["approval-deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 30), "the card's Deny is the app's own button")
        XCTAssertEqual(deny.label, "Deny")
        XCTAssertTrue(app.buttons["approval-allow"].exists)
        XCTAssertFalse(app.webViews.buttons["Deny"].exists, "the page's own pair steps aside")
        sleep(1)
        shot("06-approval-card")

        // Answered: the sheet closes, the list beneath refreshes, and says so.
        deny.tap()
        let toast = app.staticTexts["toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 30), "the answer shows as a toast")
        XCTAssertEqual(toast.label, "Denied.")
        shot("07-toast")

        // Settings, the web's /settings: every place, then Version and Sign out.
        app.tabBars.buttons["Settings"].tap()
        let you = app.webViews.links.matching(NSPredicate(format: "label BEGINSWITH %@", "You")).firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 30), "Settings lists You first")
        XCTAssertTrue(app.webViews.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch.exists)
        XCTAssertTrue(app.webViews.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Apple Watch")).firstMatch.exists)
        shot("08-settings")

        // A web settings page from it, as a sheet.
        you.tap()
        let done = app.navigationBars.buttons["sheet-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "You opens as a sheet with Done")
        XCTAssertEqual(done.label, "Done")
        sleep(2)
        shot("09-settings-page")
        done.tap()

        // Version and Sign out at the foot; Sign out, confirmed: back to the sign-in sheet.
        let signOut = settingsSignOut(in: app)
        XCTAssertTrue(reveal(signOut, in: app), "Settings ends with Sign out")
        XCTAssertTrue(element(containing: "Version", in: app).exists)
        shot("08b-settings-foot")
        signOut.tap()
        let confirm = signOutConfirmation(in: app)
        XCTAssertTrue(confirm.exists, "Sign out asks first")
        shot("10-sign-out-confirm")
        confirm.tap()
        XCTAssertTrue(developer.waitForExistence(timeout: 60), "signed out: the sign-in sheet again")
        shot("11-signed-out")

        // The server out of reach (a Debug-only launch argument points the
        // app at a port nothing answers): the app's own screen, with Try again.
        // Port 4, not 9: WebKit won't use 9 at all, and its load never ended.
        app.terminate()
        app.launchArguments = ["-LanyardBaseURL", "http://127.0.0.1:4"]
        app.launch()
        let retry = app.buttons["error-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 60), "the error screen offers Try again")
        XCTAssertTrue(element(containing: "Can't reach Lanyard", in: app).exists)
        shot("12-server-unreachable")
        app.terminate()
    }
}
