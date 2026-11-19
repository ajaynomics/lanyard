import XCTest

/// The phone app's tabs and its sheets' close buttons, as Rails serves them
/// in the path configuration (PathConfiguration), and the badge a page sets
/// on one of those tabs. Before, all three were fixed in Swift.
final class AppTabTests: XCTestCase {
    private let base = URL(string: "https://lanyard.example.org")!

    /// The path configuration's settings as Hotwire Native holds them: the
    /// JSON read with JSONSerialization (PathConfigurationDecoder).
    private func settings(_ json: String) throws -> [String: AnyHashable] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try XCTUnwrap(object?["settings"] as? [String: AnyHashable])
    }

    /// As Rails answers /configurations/ios_v3.json, but for one renamed tab.
    private let served = """
    {"settings":{"tabs":[
      {"id":"agents","title":"Agents","ios_image":"bubble.left.and.bubble.right","url":"/"},
      {"id":"needs-you","title":"Waiting","ios_image":"hand.raised","url":"/approvals"},
      {"id":"settings","title":"Settings","ios_image":"gearshape","url":"/settings"}
    ]},"rules":[]}
    """

    func testTheTabsAreTheOnesRailsServesEachWithItsOwnStart() throws {
        let tabs = AppTab.served(try settings(served))
        XCTAssertEqual(tabs.map(\.id), ["agents", "needs-you", "settings"])
        XCTAssertEqual(tabs.map(\.title), ["Agents", "Waiting", "Settings"], "renamed by Rails, with no new build")
        XCTAssertEqual(tabs.map(\.image), ["bubble.left.and.bubble.right", "hand.raised", "gearshape"])
        XCTAssertEqual(tabs[0].url(base: base), base)
        XCTAssertEqual(tabs[1].url(base: base).absoluteString, "https://lanyard.example.org/approvals")
        XCTAssertEqual(tabs[2].url(base: base).path(), "/settings")
    }

    func testWithNoTabsServedOrTabsItCantReadTheAppKeepsItsOwn() throws {
        XCTAssertEqual(AppTab.served([:]), AppTab.fallback, "an older configuration, cached or bundled")
        XCTAssertEqual(AppTab.served(try settings(#"{"settings":{"tabs":[]},"rules":[]}"#)), AppTab.fallback)
        XCTAssertEqual(AppTab.served(try settings(#"{"settings":{"tabs":[{"id":"agents"}]},"rules":[]}"#)), AppTab.fallback)
        XCTAssertEqual(AppTab.fallback.map(\.id), ["agents", "needs-you", "settings"])
        XCTAssertEqual(AppTab.fallback.map(\.title), ["Agents", "Needs you", "Settings"])
    }

    func testAPageGoesToTheTabWhoseFirstPageItIsUnderOtherwiseTheFirst() throws {
        let tabs = AppTab.served(try settings(served))
        XCTAssertEqual(tabs.holding("/approvals").id, "needs-you")
        XCTAssertEqual(tabs.holding("/approvals/7").id, "needs-you")
        XCTAssertEqual(tabs.holding("/approvalsx").id, "agents", "a whole segment, not a prefix of one")
        XCTAssertEqual(tabs.holding("/conversations/3").id, "agents")
    }

    func testTheRulesSayWhichSheetsAreLeftByCancelAndTheRestByDone() {
        XCTAssertEqual(SheetClose(properties: ["context": "modal", "close": "cancel"]), .cancel)
        XCTAssertEqual(SheetClose(properties: ["context": "modal"]), .done)
        XCTAssertEqual(SheetClose(properties: ["close": "something new"]), .done, "a word this build doesn't know")
    }

    func testTheBadgeAPageSendsIsItsCountOnTheTabItNames() throws {
        let badge = try JSONDecoder().decode(TabBadge.self, from: Data(#"{"count":4,"tab":"needs-you"}"#.utf8))
        XCTAssertEqual(badge, TabBadge(count: 4, tab: "needs-you"))
        XCTAssertEqual(badge.text, "4")
        XCTAssertNil(TabBadge(count: 0, tab: "needs-you").text, "no badge, not a zero")
        XCTAssertEqual(badge.index(in: AppTab.served(try settings(served))), 1)
        XCTAssertNil(TabBadge(count: 2, tab: "gone").index(in: AppTab.fallback), "a tab these tabs don't have")
    }
}
