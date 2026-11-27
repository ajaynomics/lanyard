import UserNotifications
import XCTest

/// A notice's buttons (docs/design.md, "A notice's buttons"): what each
/// category offers, what each button asks Rails, and only what the Watch's
/// own card and composer may ask. The strings are Rails' own
/// (Conversation::Notifiable::Buttons), which a Rails test checks against
/// this app's source.
final class NoticeRouteTests: XCTestCase {
    private let delivered = Date(timeIntervalSince1970: 1_800_000_000)

    private func notice(_ category: String?, version: String? = "v1") -> [AnyHashable: Any] {
        var aps: [String: Any] = ["alert": ["title": "Iris needs you", "body": "Allow forget note?"]]
        if let category { aps["category"] = category }
        var userInfo: [AnyHashable: Any] = ["aps": aps, "url": "/approvals/5", "conversation_id": NSNumber(value: 2), "invocation_id": NSNumber(value: 5)]
        if let version { userInfo["version"] = version }
        return userInfo
    }

    func testTheIdentifiersAreRailsStrings() {
        XCTAssertEqual(NoticeCategory.allCases.map(\.rawValue), ["APPROVAL", "NEEDS_YOU", "REPLY"])
        XCTAssertEqual(NoticeAction.allCases.map(\.rawValue), ["ALLOW_ONCE", "DECLINE", "REPLY"])
    }

    func testEachCategoryShowsOnlyTheWatchsOwnButtonsAndNeverAlways() throws {
        let categories = Dictionary(uniqueKeysWithValues: NoticeCategories.all.map { ($0.identifier, $0) })
        XCTAssertEqual(Set(categories.keys), ["APPROVAL", "NEEDS_YOU", "REPLY"])
        XCTAssertEqual(categories["APPROVAL"]?.actions.map(\.identifier), ["ALLOW_ONCE", "DECLINE"])
        XCTAssertEqual(categories["NEEDS_YOU"]?.actions.map(\.identifier), ["DECLINE"])
        XCTAssertEqual(categories["REPLY"]?.actions.map(\.identifier), ["REPLY"])
        let all = categories.values.flatMap(\.actions)
        XCTAssertFalse(all.contains { $0.title.localizedCaseInsensitiveContains("always") })
        XCTAssertTrue(all.allSatisfy { $0.options.contains(.authenticationRequired) }, "answering needs the phone unlocked")
        let decline = try XCTUnwrap(categories["APPROVAL"]?.actions.last)
        XCTAssertTrue(decline.options.contains(.destructive))
        XCTAssertTrue(categories["REPLY"]?.actions.first is UNTextInputNotificationAction, "on the phone, Reply takes words in the notice")
    }

    func testANoticeIsReadFromRailsPayload() {
        XCTAssertEqual(NoticeRoute(userInfo: notice("APPROVAL")),
                       NoticeRoute(category: .approval, conversationId: 2, invocationId: 5, version: "v1"))
        XCTAssertEqual(NoticeRoute(userInfo: ["conversation_id": NSNumber(value: 3), "aps": ["category": "REPLY"]]),
                       NoticeRoute(category: .reply, conversationId: 3, invocationId: nil, version: nil))
        XCTAssertNil(NoticeRoute(userInfo: ["url": "/conversations/3", "aps": [:] as [String: Any]]), "a notice from before names no thread")
        XCTAssertNil(NoticeRoute(userInfo: notice("SOMETHING"))?.category)
    }

    func testAllowOnceOnlyOnASmallCardAndDeclineOnlyOnACardEachAtTheVersionShown() {
        let small = NoticeRoute(userInfo: notice("APPROVAL"))
        XCTAssertEqual(small?.answer(to: "ALLOW_ONCE", text: nil, notificationId: "n", deliveredAt: delivered),
                       .decide(conversationId: 2, invocationId: 5, decision: "approve", version: "v1"))
        XCTAssertEqual(small?.answer(to: "DECLINE", text: nil, notificationId: "n", deliveredAt: delivered),
                       .decide(conversationId: 2, invocationId: 5, decision: "deny", version: "v1"))

        let long = NoticeRoute(userInfo: notice("NEEDS_YOU"))
        XCTAssertNil(long?.answer(to: "ALLOW_ONCE", text: nil, notificationId: "n", deliveredAt: delivered), "a long card is allowed only on its card")
        XCTAssertEqual(long?.answer(to: "DECLINE", text: nil, notificationId: "n", deliveredAt: delivered),
                       .decide(conversationId: 2, invocationId: 5, decision: "deny", version: "v1"))

        XCTAssertNil(NoticeRoute(userInfo: notice("APPROVAL", version: nil))?.answer(to: "ALLOW_ONCE", text: nil, notificationId: "n", deliveredAt: delivered),
                     "no version, no answer")
        XCTAssertNil(NoticeRoute(userInfo: notice(nil))?.answer(to: "DECLINE", text: nil, notificationId: "n", deliveredAt: delivered),
                     "a question has no buttons")
        XCTAssertNil(small?.answer(to: UNNotificationDefaultActionIdentifier, text: nil, notificationId: "n", deliveredAt: delivered), "a tap opens it")
        XCTAssertNil(small?.answer(to: "REPLY", text: "Yes", notificationId: "n", deliveredAt: delivered))
    }

    func testReplySendsItsWordsOnceUnderTheNoticesOwnId() {
        let reply = NoticeRoute(category: .reply, conversationId: 3, invocationId: nil, version: nil)
        XCTAssertEqual(reply.answer(to: "REPLY", text: "Sounds good", notificationId: "conversation-3", deliveredAt: delivered),
                       .reply(conversationId: 3, text: "Sounds good", requestId: "notice-1800000000-conversation-3"))
        XCTAssertNil(reply.answer(to: "REPLY", text: "  ", notificationId: "conversation-3", deliveredAt: delivered), "no words, nothing sent")
        XCTAssertNil(reply.answer(to: "ALLOW_ONCE", text: nil, notificationId: "conversation-3", deliveredAt: delivered))
        XCTAssertNotEqual(NoticeRoute.requestId(notificationId: "conversation-3", deliveredAt: delivered),
                          NoticeRoute.requestId(notificationId: "conversation-3", deliveredAt: delivered.addingTimeInterval(60)),
                          "a later notice in the same thread is a new message")

        let odd = NoticeRoute.requestId(notificationId: "a b/c" + String(repeating: "x", count: 200), deliveredAt: delivered)
        XCTAssertNotNil(odd.range(of: #"^[\w.:-]{1,128}$"#, options: .regularExpression), "Rails' shape (Agent::Access.valid_id?)")
    }

    func testThePhonePostsTheSameJSONWithItsSession() throws {
        let base = URL(string: "https://lanyard.example.org")!
        let decide = PhoneRequests.answer(base: base, .decide(conversationId: 2, invocationId: 5, decision: "approve", version: "v1"))
        XCTAssertEqual(decide.httpMethod, "POST")
        XCTAssertEqual(decide.url?.path(), "/conversations/2/invocations/5/approval.json")
        XCTAssertEqual(decide.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(decide.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(decide.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        XCTAssertEqual(try body(of: decide), ["decision": "approve", "version": "v1"])

        let reply = PhoneRequests.answer(base: base, .reply(conversationId: 3, text: "Fish & chips = yes", requestId: "notice-1"))
        XCTAssertEqual(reply.url?.path(), "/conversations/3/submissions.json")
        XCTAssertEqual(try body(of: reply), ["content": "Fish & chips = yes", "request_id": "notice-1"])
    }

    func testThePhoneSaysWhenAnAnswerWasNotDoneAndNothingWhenItWas() {
        let allow = NoticeAnswer.decide(conversationId: 2, invocationId: 5, decision: "approve", version: "v1")
        func problem(_ answer: NoticeAnswer, _ status: Int?, _ json: String = "{}") -> String? {
            NoticeReceipt.problem(answer, status: status, body: Data(json.utf8))
        }
        XCTAssertNil(problem(allow, 200, #"{"decision":"approve"}"#))
        XCTAssertEqual(problem(allow, 200, #"{"decision":"deny"}"#), "Not confirmed. Open it to check.")
        XCTAssertEqual(problem(allow, 409, #"{"error":"changed"}"#), "It changed since this notice. Open it to read it again.")
        XCTAssertEqual(problem(allow, 409, #"{"error":"phone_only"}"#), "Too long to allow from a notice. Open it to answer.")
        XCTAssertEqual(problem(allow, 409, #"{"error":"answered_or_expired"}"#), "Already answered, or it expired.")
        XCTAssertEqual(problem(allow, nil), "Signed out on this iPhone. Open Ajent to sign in.")
        XCTAssertEqual(problem(allow, 401), NoticeReceipt.signedOut)
        XCTAssertEqual(problem(allow, 503), "Not confirmed: the server failed (503). Open it to check.")
        XCTAssertEqual(problem(allow, 302), "Not sent: the server answered 302.")
        XCTAssertEqual(allow.path, "/approvals/5")

        let reply = NoticeAnswer.reply(conversationId: 3, text: "Yes", requestId: "notice-1")
        XCTAssertNil(problem(reply, 202, #"{"conversation_id":3,"request_id":"notice-1","accepted":true}"#))
        XCTAssertEqual(problem(reply, 202, #"{"request_id":"other","accepted":true}"#), "Not confirmed. Open the thread to check.")
        XCTAssertEqual(problem(reply, 409, #"{"error":"paused"}"#), "Not sent: the server answered 409.")
        XCTAssertEqual(reply.path, "/conversations/3")
    }

    private func body(of request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }
}
