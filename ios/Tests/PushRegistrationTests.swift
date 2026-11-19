import XCTest

/// The phone posts its notifications token to Rails as soon as iOS gives it,
/// with no Turn on tap. A TestFlight build already signed in never did: iOS
/// gave the token at each launch, the app kept it, and Rails had no device.
final class PushRegistrationTests: XCTestCase {
    @MainActor
    func testATokenFromIOSIsPostedToRailsWithNoTurnOnTap() async throws {
        defer { PushRegistration.storedToken = nil }
        let registration = PushRegistration()
        let sent = SentRequests()
        registration.send = { request in
            sent.requests.append(request)
            return 201
        }

        await registration.received(Data([UInt8](0xa0...0xbf))).value

        XCTAssertEqual(sent.requests.count, 1, "one post, from the token alone")
        let request = try XCTUnwrap(sent.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, baseURL.appendingPathComponent("push/devices.json"))
        XCTAssertEqual(request.url?.path(), "/push/devices.json")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
                       "token=a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
        XCTAssertEqual(PushRegistration.storedToken, "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf",
                       "kept for sign-in and sign-out")
    }

    /// Production, 2026-11-15: Turn on was tapped and no token came. A refused
    /// permission or a failed registration left the tap waiting for ever, and
    /// the page said nothing. Now each waiter hears why, once.
    @MainActor
    func testARefusedOrFailedRegistrationTellsWhoWaitsWhy() async {
        let registration = PushRegistration()
        registration.send = { _ in 201 }
        let heard = Heard()

        registration.nextToken { heard.answers.append($0) }
        await registration.noToken(.refused).value
        registration.nextToken { heard.answers.append($0) }
        await registration.noToken(.failed).value
        await registration.noToken(.failed).value

        XCTAssertEqual(heard.answers, [.failure(.refused), .failure(.failed)], "each waiter hears once, and why")
    }

    /// Production, 2026-11-15: notifications allowed, no device in Rails, and
    /// nobody could tell a tap that never reached the app from iOS refusing.
    /// Now Rails hears why iOS gave no token, with iOS's error code, and never
    /// a token.
    @MainActor
    func testWhyIOSGaveNoTokenIsPostedToRailsWithItsCode() async throws {
        defer { PushRegistration.storedToken = nil }
        PushRegistration.storedToken = "a0a1a2a3"
        let registration = PushRegistration()
        let sent = SentRequests()
        registration.send = { request in
            sent.requests.append(request)
            return 201
        }

        await registration.noToken(.failed, code: 3010).value
        await registration.noToken(.refused).value

        XCTAssertEqual(sent.requests.map { $0.url?.path() }, ["/push/attempts.json", "/push/attempts.json"])
        XCTAssertEqual(sent.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) },
                       ["outcome=failed&code=3010", "outcome=refused"], "why and iOS's code, never the token")
        XCTAssertTrue(sent.requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Lanyard/") == true)
    }
}

/// What the waiters for a token heard.
@MainActor
private final class Heard {
    var answers: [Result<String, PushRegistration.NoToken>] = []
}

/// What the stand-in sender was asked to send.
@MainActor
private final class SentRequests {
    var requests: [URLRequest] = []
}
