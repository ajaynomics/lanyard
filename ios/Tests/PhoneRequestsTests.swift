import XCTest

/// The phone app's own pieces that need no screen: the requests it makes to
/// Rails beside its web views, where a tapped notification goes, and what its
/// error screen says. Its tabs and sheets' close buttons: AppTabTests.
final class PhoneRequestsTests: XCTestCase {
    private let base = URL(string: "https://lanyard.example.org")!

    func testADeviceTokenIsRegisteredAsHexWithItsPushService() throws {
        XCTAssertEqual(DeviceToken.hex(Data([0x00, 0xab, 0xff])), "00abff")
        let request = PhoneRequests.registerDevice(base: base, token: "00abff", environment: "sandbox")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path(), "/push/devices.json")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self), "token=00abff")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Lanyard APNs/sandbox")
    }

    func testWhyThereIsNoTokenIsReportedWithTheBuildsVersion() throws {
        let request = PhoneRequests.reportAttempt(base: base, outcome: "failed", code: 3010, version: "0.1(12)")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path(), "/push/attempts.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self), "outcome=failed&code=3010")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Lanyard/0.1(12) APNs/\(DeviceToken.environment)")
    }

    func testANotificationOpensItsPageOnThisInstallOnly() {
        // The tab that holds it is the served tabs' to say, when it opens (AppTabTests).
        XCTAssertEqual(DeepLink(userInfo: ["url": "/approvals/7"], base: base)?.url.absoluteString,
                       "https://lanyard.example.org/approvals/7")

        XCTAssertNil(DeepLink(userInfo: ["url": "https://elsewhere.example.com/approvals/7"], base: base))
        XCTAssertNil(DeepLink(userInfo: ["url": "//elsewhere.example.com/x"], base: base))
        XCTAssertNil(DeepLink(userInfo: [:], base: base))
    }

    func testTheErrorScreenSaysWhatWentWrongInPlainWords() {
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: .notConnectedToInternet).title, "You're offline")
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: .cannotConnectToHost).title, "Can't reach Lanyard")
        XCTAssertEqual(ErrorCopy(statusCode: 401, urlError: nil).action, "Sign in")
        XCTAssertEqual(ErrorCopy(statusCode: 404, urlError: nil).title, "Not found")
        XCTAssertEqual(ErrorCopy(statusCode: 502, urlError: nil).title, "Something went wrong")
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: nil).action, "Try again")
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: nil, network: true).title, "Can't reach Lanyard",
                       "a connection error Turbo.js reported, with no iOS code")
    }
}
