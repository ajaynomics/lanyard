import UserNotifications
import XCTest

/// Tapping a notice killed the phone app (TestFlight, 2026-11-16): its
/// notification delegate ran off the main thread, and iOS's completion handler
/// was called from there. Now a tap or a button is handled on the main actor,
/// whichever thread iOS calls from, and a button's answer is sent before the
/// handler returns. Each tap here starts off the main thread, as iOS's may.
/// The delegate itself, called by iOS from a banner after a cold launch, is
/// PhoneNoticeTapUITests'; a device and Apple's push are BUILD.md's.
final class NoticeTapTests: XCTestCase {
    /// The app was not running: the tap launches it, and its page opens once
    /// SceneController is ready and a page has loaded signed in
    /// (NotificationRouterTests holds the rest).
    @MainActor
    func testATapAtColdStartOpensItsPageOnceTheSceneIsReady() async {
        let registration = PushRegistration()
        let opened = Opened()

        await Task.detached { await tap(registration, url: "/approvals/7") }.value
        XCTAssertTrue(opened.links.isEmpty, "nothing to open it in yet")

        registration.router.ready { link in
            opened.links.append(link)
            opened.onMain.append(Thread.isMainThread)
            return true
        }
        XCTAssertTrue(opened.links.isEmpty, "no page has loaded yet")
        registration.router.pageLoaded()

        XCTAssertEqual(opened.links, [DeepLink(userInfo: ["url": "/approvals/7"], base: baseURL)].compactMap { $0 })
        XCTAssertEqual(opened.onMain, [true])
    }

    /// The app was in the background, or open in front: its page opens now,
    /// on the main thread.
    @MainActor
    func testATapWhileTheAppRunsOpensItsPageOnTheMainThread() async {
        let registration = PushRegistration()
        let opened = Opened()
        registration.router.ready { link in
            opened.links.append(link)
            opened.onMain.append(Thread.isMainThread)
            return true
        }
        registration.router.pageLoaded()

        await Task.detached { await tap(registration, url: "/conversations/3") }.value
        await Task.detached { await tap(registration, url: "/approvals/7") }.value

        XCTAssertEqual(opened.links.map { $0.url.path() }, ["/conversations/3", "/approvals/7"])
        XCTAssertEqual(opened.onMain, [true, true])
    }

    /// A tap on a notice from elsewhere, or one naming no page, opens nothing.
    @MainActor
    func testATapNamingNoPageOfThisInstallOpensNothing() async {
        let registration = PushRegistration()
        let opened = Opened()
        registration.router.ready { opened.links.append($0); return true }
        registration.router.pageLoaded()

        await Task.detached { await tap(registration, url: "https://elsewhere.example.com/approvals/7") }.value
        await Task.detached { await tap(registration, url: nil) }.value

        XCTAssertTrue(opened.links.isEmpty)
    }

    /// A button is answered on the main actor (by NotificationActions in the app), and
    /// the handler returns only once the answer is done: iOS may suspend the
    /// app as soon as it returns.
    @MainActor
    func testAButtonIsAnsweredOnTheMainActorBeforeTheHandlerReturns() async {
        let registration = PushRegistration()
        let opened = Opened()
        registration.router.ready { opened.links.append($0); return true }
        registration.router.pageLoaded()
        let answered = Answered()

        await Task.detached { await tap(registration, url: "/approvals/5", action: NoticeAction.allowOnce.rawValue, answered: answered) }.value
        await Task.detached {
            await tap(registration, url: "/conversations/2", action: NoticeAction.reply.rawValue, category: "REPLY", text: "Sounds good",
                      answered: answered)
        }.value

        XCTAssertEqual(answered.answers, [
            .decide(conversationId: 2, invocationId: 5, decision: "approve", version: "v1"),
            .reply(conversationId: 2, text: "Sounds good", requestId: NoticeRoute.requestId(notificationId: "conversation-2", deliveredAt: delivered))
        ])
        XCTAssertEqual(answered.onMain, [true, true])
        XCTAssertTrue(opened.links.isEmpty, "a button answers in the background; it opens nothing")
    }
}

private let delivered = Date(timeIntervalSince1970: 1_800_000_000)

/// A tap or a button, as the delegate reads it from iOS's response: Rails'
/// payload with its ids and the card's version. A button's answer is recorded
/// in place of NotificationActions', after a suspension, as a request's would be.
@MainActor
private func tap(_ registration: PushRegistration, url: String?, action: String = UNNotificationDefaultActionIdentifier,
                 category: String = "APPROVAL", text: String? = nil, answered: Answered? = nil) async {
    var userInfo: [AnyHashable: Any] = ["aps": ["category": category], "conversation_id": NSNumber(value: 2),
                                        "invocation_id": NSNumber(value: 5), "version": "v1"]
    if let url { userInfo["url"] = url }
    let answered = answered ?? Answered()
    let tap = NoticeTap(userInfo: userInfo, action: action, text: text, notificationId: "conversation-2", deliveredAt: delivered)
    await registration.respond(to: tap) { answer in
        answered.onMain.append(onMainThread())
        await Task.yield()
        answered.answers.append(answer)
    }
}

/// Thread.isMainThread is not offered in an async context; this asks from a synchronous one.
private func onMainThread() -> Bool {
    Thread.isMainThread
}

/// The pages a tap opened, and whether each opened on the main thread.
@MainActor
private final class Opened {
    var links: [DeepLink] = []
    var onMain: [Bool] = []
}

/// The buttons' answers, and whether each was sent from the main thread.
@MainActor
private final class Answered {
    var answers: [NoticeAnswer] = []
    var onMain: [Bool] = []
}
