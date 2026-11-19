import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "org.durableassistants", category: "phone-push")

/// A notice's button answered on the phone, in the background (docs/design.md,
/// "A notice's buttons"): the request goes to Rails with the person's web
/// session (WebSession), as TokenMint's does. Done says nothing. Anything
/// else (refused, signed out, lost on the way) says so in a notice of its own,
/// whose tap opens the card or the thread: nothing is queued or sent again.
@MainActor
enum NotificationActions {
    static func answer(_ answer: NoticeAnswer) async {
        let problem: String?
        do {
            let reply = try await WebSession(base: baseURL).send(PhoneRequests.answer(base: baseURL, answer))
            log.notice("notice answered: HTTP \(reply?.status ?? 0)")
            problem = NoticeReceipt.problem(answer, status: reply?.status, body: reply?.body ?? Data())
        } catch {
            log.error("notice answer failed \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            problem = NoticeReceipt.lost
        }
        guard let problem else { return }
        await tell(problem, about: answer)
    }

    private static func tell(_ problem: String, about answer: NoticeAnswer) async {
        let content = UNMutableNotificationContent()
        content.title = "Not done"
        content.body = problem
        content.threadIdentifier = "conversation-\(answer.conversationId)"
        // Where a tap opens (DeepLink), as Rails' own notices say it.
        content.userInfo = ["url": answer.path]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            log.error("could not say the answer was not done \((error as NSError).code)")
        }
    }
}
