@preconcurrency import Security
import XCTest

/// What the Watch sends Rails, what it makes of each answer (success only when
/// Rails says so), how it keeps its token, and the handoff with the phone.
final class WatchProtocolTests: XCTestCase {
    private let card = #"{"id":5,"conversation_id":2,"agent":"Watch fixture","title":"Allow forget note?","recipients":[],"fields":[{"label":"Key","text":"parking-spot"}],"note":null,"state":"approved","decision":"approve","version":"v1","expires_at":null,"small":true}"#
    private let base = URL(string: "http://localhost:3000")!

    func testEachRequestIsOneFixedPathWithTheTokenAndNoCookie() throws {
        let list = WatchRequest.list.urlRequest(base: base, token: "t0k")
        XCTAssertEqual(list.url?.absoluteString, "http://localhost:3000/conversations.json")
        XCTAssertEqual(list.httpMethod, "GET")
        XCTAssertNil(list.httpBody)
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(list.httpShouldHandleCookies)

        let decide = WatchRequest.decide(conversationId: 2, invocationId: 5, decision: .deny, version: "v1").urlRequest(base: base, token: "t0k")
        XCTAssertEqual(decide.url?.path, "/conversations/2/invocations/5/approval.json")
        XCTAssertEqual(decide.httpMethod, "POST")
        XCTAssertEqual(decide.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(decide.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertEqual(try body(of: decide), ["decision": "deny", "version": "v1"])

        let send = WatchRequest.send(conversationId: 2, text: "Hi", requestId: "watch-1").urlRequest(base: base, token: "t0k")
        XCTAssertEqual(send.url?.path, "/conversations/2/submissions.json")
        XCTAssertEqual(try body(of: send), ["content": "Hi", "request_id": "watch-1"])
        XCTAssertNil(send.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(WatchRequest.list.changesSomething)
        XCTAssertTrue(WatchRequest.send(conversationId: 2, text: "Hi", requestId: "watch-1").changesSomething)
    }

    func testTheTokenIsKeptOnThisDeviceOnlyAfterFirstUnlockForThisInstall() {
        let store = TokenStore(base: base)
        let item = store.item("t0k")
        XCTAssertEqual(item[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(item[kSecAttrService as String] as? String, "org.durableassistants.watch-token")
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, "http://localhost:3000")
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(item[kSecValueData as String] as? Data, Data("t0k".utf8))
        XCTAssertNil(item[kSecAttrSynchronizable as String], "never synced to another device")
        // Reading and deleting name the item, never the token.
        XCTAssertNil(store.query[kSecValueData as String])
        XCTAssertEqual(TokenStore(base: URL(string: "https://other.example")!).query[kSecAttrAccount as String] as? String, "https://other.example")
    }

    func testTheHandoffCarriesAnAskOrATokenAndNothingElse() {
        XCTAssertEqual(TokenHandoff(TokenHandoff.ask(watchName: "Robin's Watch").userInfo), .ask(watchName: "Robin's Watch"))
        XCTAssertEqual(TokenHandoff(TokenHandoff.token("t0k").userInfo), .token("t0k"))
        XCTAssertNil(TokenHandoff(["token": ""]))
        XCTAssertNil(TokenHandoff(["list": true]))
        XCTAssertEqual(TokenHandoff.token("t0k").kind, "token")
        XCTAssertEqual(TokenHandoff(TokenHandoff.signedOut.userInfo), .signedOut)
        XCTAssertNil(TokenHandoff(["signedOut": false]))
    }

    func testADecisionIsConfirmedOnlyByRailsSayingThatDecision() {
        guard case .decided(let decided) = DecisionOutcome(.answered(status: 200, body: Data(card.utf8)), asked: .approve) else {
            return XCTFail("expected decided")
        }
        XCTAssertEqual(decided.id, 5)
        XCTAssertEqual(DecisionOutcome(.answered(status: 200, body: Data(card.utf8)), asked: .deny),
                       .unconfirmed("The answer did not confirm the decision."))
        XCTAssertEqual(DecisionOutcome(.answered(status: 200, body: Data("<html>".utf8)), asked: .approve),
                       .unconfirmed("The answer did not confirm the decision."))
    }

    func testRefusalsLostAnswersAndARefusedToken() {
        let changed = card.replacingOccurrences(of: #""small":true"#, with: #""small":true,"error":"changed""#)
        guard case .refused(.changed, _) = DecisionOutcome(.answered(status: 409, body: Data(changed.utf8)), asked: .approve) else {
            return XCTFail("expected changed")
        }
        XCTAssertEqual(DecisionOutcome(.answered(status: 401, body: Data()), asked: .approve), .signedOut)
        XCTAssertEqual(DecisionOutcome(.answered(status: 302, body: Data()), asked: .approve), .failed("The server answered 302."))
        XCTAssertEqual(DecisionOutcome(.answered(status: 503, body: Data()), asked: .approve), .unconfirmed("The server failed (503)."))
        XCTAssertEqual(DecisionOutcome(.notSent(reason: "away"), asked: .approve), .failed("away"))
        XCTAssertEqual(DecisionOutcome(.unconfirmed(reason: "lost"), asked: .deny), .unconfirmed("lost"))
    }

    func testAMessageIsAcceptedOnlyUnderItsOwnId() {
        let body = Data(#"{"conversation_id":2,"request_id":"watch-1","accepted":true}"#.utf8)
        XCTAssertEqual(SendOutcome(.answered(status: 202, body: body), requestId: "watch-1"), .accepted(requestId: "watch-1"))
        XCTAssertEqual(SendOutcome(.answered(status: 202, body: body), requestId: "watch-2"), .unconfirmed("The answer did not confirm the message."))
        XCTAssertEqual(SendOutcome(.answered(status: 200, body: body), requestId: "watch-1"), .failed("The server answered 200."))
        XCTAssertEqual(SendOutcome(.answered(status: 401, body: Data()), requestId: "watch-1"), .signedOut)
        XCTAssertEqual(SendOutcome(.answered(status: 503, body: Data()), requestId: "watch-1"), .unconfirmed("The agent may not have it (503)."))
        XCTAssertEqual(SendOutcome(.unconfirmed(reason: "lost"), requestId: "watch-1"), .unconfirmed("lost"))
    }

    func testRequestIdsAreNewEachTimeAndRailsShaped() {
        let id = newRequestId()
        XCTAssertNotEqual(id, newRequestId())
        XCTAssertNotNil(id.range(of: #"^[\w.:-]{1,128}$"#, options: .regularExpression))
    }

    func testTheListFailsClosed() {
        let listing = Data(#"{"agents":[{"conversation_id":2,"name":"Watch fixture"}],"approvals":[]}"#.utf8)
        XCTAssertEqual(ListOutcome(.answered(status: 200, body: listing)), .loaded(Listing(agents: [AgentRow(conversationId: 2, name: "Watch fixture")], approvals: [])))
        XCTAssertEqual(ListOutcome(.answered(status: 401, body: Data())), .signedOut)
        XCTAssertEqual(ListOutcome(.answered(status: 200, body: Data("<html>".utf8))), .failed("The answer could not be read."))
        XCTAssertEqual(ListOutcome(.notSent(reason: "away")), .failed("away"))
    }

    func testAThreadIsReadWithTheTokenAndEarlierPagesByTheirEntry() {
        let newest = WatchRequest.thread(conversationId: 2, before: nil).urlRequest(base: base, token: "t0k")
        XCTAssertEqual(newest.url?.absoluteString, "http://localhost:3000/conversations/2/messages.json")
        XCTAssertEqual(newest.httpMethod, "GET")
        XCTAssertNil(newest.httpBody)
        XCTAssertEqual(newest.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertEqual(newest.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(newest.httpShouldHandleCookies)
        XCTAssertEqual(WatchRequest.thread(conversationId: 2, before: 6).urlRequest(base: base, token: "t0k").url?.absoluteString,
                       "http://localhost:3000/conversations/2/messages.json?before=6")
        XCTAssertFalse(WatchRequest.thread(conversationId: 2, before: nil).changesSomething, "reading changes nothing")
        XCTAssertEqual(WatchRequest.thread(conversationId: 2, before: nil).kind, "thread")
    }

    func testAThreadReadsAsRailsSendsItAndFailsClosed() {
        let page = Data(#"{"conversation_id":2,"agent":"Watch fixture","messages":[{"id":7,"role":"user","text":"Book Lisbon","at":"2026-11-16T09:00:00Z"},{"id":8,"role":"assistant","text":"Booked.","at":"2026-11-16T09:01:00Z"}],"earlier":6}"#.utf8)
        guard case .loaded(let thread) = ThreadOutcome(.answered(status: 200, body: page)) else { return XCTFail("expected loaded") }
        XCTAssertEqual(thread.agent, "Watch fixture")
        XCTAssertEqual(thread.messages.map(\.text), ["Book Lisbon", "Booked."])
        XCTAssertEqual(thread.messages.map(\.fromPerson), [true, false])
        XCTAssertEqual(thread.earlier, 6)

        let start = Data(#"{"conversation_id":2,"agent":"Watch fixture","messages":[],"earlier":null}"#.utf8)
        guard case .loaded(let empty) = ThreadOutcome(.answered(status: 200, body: start)) else { return XCTFail("expected loaded") }
        XCTAssertNil(empty.earlier)
        XCTAssertEqual(ThreadOutcome(.answered(status: 401, body: Data())), .signedOut)
        XCTAssertEqual(ThreadOutcome(.answered(status: 404, body: Data())), .gone)
        XCTAssertEqual(ThreadOutcome(.answered(status: 200, body: Data("<html>".utf8))), .failed("The answer could not be read."))
        XCTAssertEqual(ThreadOutcome(.notSent(reason: "away")), .failed("away"))
    }

    func testANoticesButtonIsTheWatchsOwnRequest() {
        XCTAssertEqual(WatchRequest(.decide(conversationId: 2, invocationId: 5, decision: "approve", version: "v1")),
                       .decide(conversationId: 2, invocationId: 5, decision: .approve, version: "v1"))
        XCTAssertEqual(WatchRequest(.reply(conversationId: 2, text: "Yes", requestId: "notice-1")),
                       .send(conversationId: 2, text: "Yes", requestId: "notice-1"))
        XCTAssertNil(WatchRequest(.decide(conversationId: 2, invocationId: 5, decision: "always", version: "v1")), "never anything but approve or deny")
    }

    private func body(of request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }
}
