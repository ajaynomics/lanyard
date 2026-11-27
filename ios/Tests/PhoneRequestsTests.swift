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

    func testLocationFixStaysInTheBodyForItsOwnConversationAndInvocation() throws {
        let fix = PhoneRequests.LocationFix(latitude: 49.25, longitude: -123.12, accuracy_m: 16.5,
                                            timestamp: Date(timeIntervalSince1970: 0))
        let request = try XCTUnwrap(PhoneRequests.locationResult(base: base, conversation: "12", invocation: "47",
                                                                 outcome: "shared", fix: fix))
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://lanyard.example.org/conversations/12/invocations/47/location_request.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let sent = try XCTUnwrap(body["location_fix"] as? [String: Any])
        XCTAssertEqual(body["outcome"] as? String, "shared")
        XCTAssertEqual(sent["latitude"] as? Double, 49.25)
        XCTAssertEqual(sent["longitude"] as? Double, -123.12)
        XCTAssertEqual(sent["accuracy_m"] as? Double, 16.5)
        XCTAssertEqual(sent["timestamp"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertNil(PhoneRequests.locationResult(base: base, conversation: "//elsewhere.example/12", invocation: "47",
                                                  outcome: "shared", fix: fix))
    }

    func testPermissionFailuresKeepTheirOwnOutcomeAndDoNotSendAFix() throws {
        for outcome in ["denied", "restricted", "services_off"] {
            let request = try XCTUnwrap(PhoneRequests.locationResult(base: base, conversation: "12", invocation: "47",
                                                                     outcome: outcome, fix: nil))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(body, ["outcome": outcome])
        }
    }

    /// Notifications turned off later in the iPhone's Settings: the app says
    /// so each time it comes to the front. Rails keeps the report it receives
    /// last, so neither says when the app asked: the phone's clock can be wrong.
    func testEachReportCarriesNoTimeFromThePhone() throws {
        let token = PhoneRequests.registerDevice(base: base, token: "00abff", environment: "sandbox")
        XCTAssertEqual(String(decoding: try XCTUnwrap(token.httpBody), as: UTF8.self), "token=00abff")
        let refused = PhoneRequests.reportAttempt(base: base, outcome: "refused", code: nil, version: "0.1(12)")
        XCTAssertEqual(String(decoding: try XCTUnwrap(refused.httpBody), as: UTF8.self), "outcome=refused")
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
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: .cannotConnectToHost).title, "Can't reach Ajent")
        XCTAssertEqual(ErrorCopy(statusCode: 401, urlError: nil).action, "Sign in")
        XCTAssertEqual(ErrorCopy(statusCode: 404, urlError: nil).title, "Not found")
        XCTAssertEqual(ErrorCopy(statusCode: 502, urlError: nil).title, "Something went wrong")
        XCTAssertEqual(ErrorCopy(statusCode: 502, urlError: nil).message, "Ajent couldn't load this page. Try again in a moment.")
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: nil).action, "Try again")
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: nil).message, "Ajent couldn't load this page.")
        XCTAssertEqual(ErrorCopy(statusCode: nil, urlError: nil, network: true).title, "Can't reach Ajent",
                       "a connection error Turbo.js reported, with no iOS code")
    }
}
