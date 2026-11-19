import XCTest

/// A tapped notice's page: only a page of this install, held until the app
/// has tabs and a page of them has loaded signed in, then opened once
/// (NotificationRouter). SceneController tells the router: `ready` at launch,
/// `tabsBuilt` each time it builds tabs, `pageLoaded` after each page that
/// loaded while not waiting on a sign-in (a 401 starts that wait first).
final class NotificationRouterTests: XCTestCase {
    private let base = URL(string: "https://lanyard.example.com")!

    @MainActor
    func testAPathOnThisInstallOpensAsAnAbsoluteURLInItsTab() async {
        let (router, opened) = signedInRouter()

        router.route("/approvals/7")
        router.route("/conversations/3?from=notice")

        XCTAssertEqual(opened.links.map(\.url.absoluteString),
                       ["https://lanyard.example.com/approvals/7", "https://lanyard.example.com/conversations/3?from=notice"])
        // The tab is the served tabs' choice (SceneController), the app's own here.
        XCTAssertEqual(opened.links.map { AppTab.fallback.holding($0.url.path()).id }, ["needs-you", "agents"])
    }

    @MainActor
    func testARelativePathOpensNothing() async {
        let (router, opened) = signedInRouter()

        router.route("approvals/7")
        router.route("../approvals/7")
        router.route("")

        XCTAssertTrue(opened.links.isEmpty)
        XCTAssertNil(router.pending)
    }

    @MainActor
    func testAnotherHostOpensNothing() async {
        let (router, opened) = signedInRouter()

        router.route("https://elsewhere.example.com/approvals/7")
        router.route("//elsewhere.example.com/approvals/7")
        router.route("https://lanyard.example.com:8443/approvals/7")

        XCTAssertTrue(opened.links.isEmpty)
        XCTAssertNil(router.pending)
    }

    @MainActor
    func testANoticeNamingNoPageOpensNothing() async {
        let (router, opened) = signedInRouter()

        router.route(nil)

        XCTAssertTrue(opened.links.isEmpty)
        XCTAssertNil(router.pending)
    }

    /// A cold launch: iOS hands over the tap before SceneController has tabs.
    @MainActor
    func testATapBeforeTheTabsExistIsHeldUntilTheirFirstPageLoads() async {
        let router = NotificationRouter(base: base)
        let opened = Routed()

        router.route("/approvals/7")
        XCTAssertEqual(router.pending?.url.path(), "/approvals/7", "held, with nothing to open it in")

        router.ready(open: opened.open)
        router.tabsBuilt()
        XCTAssertTrue(opened.links.isEmpty, "tabs, but no page has said whether the app is signed in")

        router.pageLoaded()
        XCTAssertEqual(opened.links.map { $0.url.path() }, ["/approvals/7"])
        XCTAssertNil(router.pending)

        router.pageLoaded()
        router.tabsBuilt()
        router.pageLoaded()
        XCTAssertEqual(opened.links.count, 1, "opened once")
    }

    /// A cold launch while signed out: SessionGate starts signed in, so the
    /// tabs are built as if signed in; their first page answers 401 and
    /// SceneController never says it loaded. Signing in rebuilds the tabs,
    /// whose first page does.
    @MainActor
    func testATapWhileSignedOutOpensOnceAfterSigningIn() async {
        let router = NotificationRouter(base: base)
        let opened = Routed()
        router.ready(open: opened.open)
        router.tabsBuilt()

        router.route("/approvals/7")
        // The first page's 401, then the sign-in sheet's pages: no pageLoaded.
        XCTAssertTrue(opened.links.isEmpty, "not opened into a 401")
        XCTAssertEqual(router.pending?.url.path(), "/approvals/7")

        // Signed in: fresh tabs, and their first page loads.
        router.tabsBuilt()
        XCTAssertTrue(opened.links.isEmpty)
        router.pageLoaded()
        XCTAssertEqual(opened.links.map { $0.url.path() }, ["/approvals/7"])

        router.pageLoaded()
        router.tabsBuilt()
        router.pageLoaded()
        XCTAssertEqual(opened.links.count, 1, "opened once")
        XCTAssertNil(router.pending)
    }

    /// Signed in, then refused (the session ended): SceneController can't
    /// open while it waits on the sign-in, so the tap is held for the
    /// rebuilt tabs' first page.
    @MainActor
    func testATapWhileWaitingOnASignInIsHeldUntilTheRebuiltTabsLoad() async {
        let (router, opened) = signedInRouter()
        opened.canOpen = false

        router.route("/approvals/7")
        XCTAssertTrue(opened.links.isEmpty)
        XCTAssertNotNil(router.pending)

        opened.canOpen = true
        router.tabsBuilt()
        router.pageLoaded()
        XCTAssertEqual(opened.links.map { $0.url.path() }, ["/approvals/7"])
        XCTAssertNil(router.pending)
    }

    /// Two taps before a page can open: only the latest opens, once.
    @MainActor
    func testOfTwoHeldTapsTheLatestOpens() async {
        let router = NotificationRouter(base: base)
        let opened = Routed()

        router.route("/conversations/1")
        router.route("/approvals/7")
        router.ready(open: opened.open)
        router.tabsBuilt()
        router.pageLoaded()
        router.pageLoaded()

        XCTAssertEqual(opened.links.map { $0.url.path() }, ["/approvals/7"], "the latest tap, once")
    }

    /// Two taps once pages can open: each is a tap, and each opens, in turn.
    @MainActor
    func testTwoTapsWhileSignedInOpenInTurn() async {
        let (router, opened) = signedInRouter()

        router.route("/conversations/1")
        router.route("/approvals/7")

        XCTAssertEqual(opened.links.map { $0.url.path() }, ["/conversations/1", "/approvals/7"])
    }

    /// Launched, tabs built and their first page loaded signed in.
    @MainActor
    private func signedInRouter() -> (NotificationRouter, Routed) {
        let router = NotificationRouter(base: base)
        let opened = Routed()
        router.ready(open: opened.open)
        router.tabsBuilt()
        router.pageLoaded()
        return (router, opened)
    }
}

/// What SceneController was asked to open, and whether it could.
@MainActor
private final class Routed {
    var links: [DeepLink] = []
    var canOpen = true

    func open(_ link: DeepLink) -> Bool {
        guard canOpen else { return false }
        links.append(link)
        return true
    }
}
