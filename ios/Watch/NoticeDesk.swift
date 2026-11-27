import os
import SwiftUI
import UserNotifications

/// What a notice did on the Watch, for `log show` (BUILD.md): its category,
/// the button and Rails' status. Never its words.
private let log = Logger(subsystem: "org.durableassistants", category: "watch-notice")

/// A notice on the Watch (docs/design.md, "A notice's buttons"): a tap opens
/// its card, or else its thread; Allow once and Decline answer the card the
/// notice named, at the version it named, as the card's own buttons would;
/// Reply opens the composer for that thread. Each opens the app, which says
/// what Rails answered. Nothing is queued: a refused or lost answer says so.
@MainActor
final class NoticeDesk: NSObject, ObservableObject {
    static let shared = NoticeDesk()

    /// The inbox's navigation, so a notice can open a card or a thread in it.
    @Published var path = NavigationPath()
    /// What Rails answered to a notice's button, shown over the inbox.
    @Published var answered: NoticeAnswered?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NoticeCategories.all)
    }

    private func handle(_ route: NoticeRoute, action: String, answer: NoticeAnswer?) async {
        log.notice("notice \(route.category?.rawValue ?? "none", privacy: .public) action=\(action, privacy: .public)")
        if let answer, let request = WatchRequest(answer), case let .decide(_, _, decision, _) = request {
            let outcome = DecisionOutcome(await Rails.send(request), asked: decision)
            answered = NoticeAnswered(outcome)
            outcome.haptic.play()
            // A card that changed shows again as it is now, to read before answering.
            if case .refused(.changed, let current) = outcome { path = NavigationPath([current]) }
            return
        }
        await open(route, toReply: action == NoticeAction.reply.rawValue)
    }

    /// The card the notice named while it still waits, else its thread, and
    /// for Reply the composer over it. The list says which cards still wait.
    private func open(_ route: NoticeRoute, toReply: Bool) async {
        let list = ListOutcome(await Rails.send(.list))
        let listing: Listing?
        if case .loaded(let loaded) = list { listing = loaded } else { listing = nil }
        let name = listing?.agents.first(where: { $0.conversationId == route.conversationId })?.name ?? ""
        let agent = AgentRow(conversationId: route.conversationId, name: name)
        var path = NavigationPath()
        if !toReply, let id = route.invocationId, let card = listing?.approvals.first(where: { $0.id == id }) {
            path.append(card)
        } else {
            path.append(agent)
            if toReply { path.append(Reply(agent: agent)) }
        }
        self.path = path
    }
}

/// As the phone's (PushRegistration+Notices.swift): iOS may call these on a
/// queue of its own, and its completion handler must be called on the main
/// thread. So each is `nonisolated`, takes iOS's completion handler, reads
/// what it needs where it is called and finishes on the main actor, calling
/// the handler there on every path. The `async` variants left it to Swift's
/// bridging where the handler was called (test/native_notice_isolation_test.rb).
extension NoticeDesk: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let done = NoticeCompletion { completionHandler([.banner, .list, .sound]) }
        Task { @MainActor in done.call() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification = response.notification
        let route = NoticeRoute(userInfo: notification.request.content.userInfo)
        let action = response.actionIdentifier
        // No words on the Watch: its Reply opens the composer.
        let answer = route?.answer(to: action, text: nil, notificationId: notification.request.identifier, deliveredAt: notification.date)
        let done = NoticeCompletion(call: completionHandler)
        Task { @MainActor in
            if let route { await self.handle(route, action: action, answer: answer) }
            done.call()
        }
    }
}

/// Rails' answer to a notice's Allow once or Decline, in the card's own words
/// (CardView): done only when Rails confirms it.
struct NoticeAnswered: Identifiable {
    let id = UUID()
    let words: String
    let done: Bool

    init(_ outcome: DecisionOutcome) {
        switch outcome {
        case .decided(let card):
            words = card.decision == "approve" ? "Allowed." : "Declined."
            done = true
            return
        case .refused(.changed, _):
            words = "This changed since the notice. Read it again before answering."
        case .refused(.phoneOnly, _):
            words = "Too long to allow here. Answer it on your iPhone."
        case .refused(.answeredOrExpired, let current):
            words = current.decision.map { "Already answered: \($0 == "approve" ? "allowed" : "declined")." } ?? "This has expired."
        case .signedOut:
            words = Reconnect.message
        case .failed(let reason):
            words = "Not sent. \(reason)"
        case .unconfirmed(let reason):
            words = "Not confirmed. \(reason) Open the card to check."
        }
        done = false
    }
}
