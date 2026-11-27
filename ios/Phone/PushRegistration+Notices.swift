import UIKit
import UserNotifications

/// PushRegistration's side that needs UIKit: asking iOS for the token, showing
/// a notice that arrives while the app is open, a tapped notice, and a
/// notice's buttons (NoticeCategories, NotificationActions).
extension PushRegistration {
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NoticeCategories.all)
        askForToken()
    }

    /// At launch and on each return to the app (SceneController), Rails hears
    /// what iOS allows now, so the web's Settings says so. Allowed: iOS gives
    /// the token again, cheaply, and `received` posts it, so notifications
    /// turned on in the iPhone's Settings reach Rails. Refused: Rails hears
    /// that, so notifications turned off there say Off rather than On while
    /// Rails still holds the token. Not yet asked: nothing.
    func askForToken() {
        Task {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized: UIApplication.shared.registerForRemoteNotifications()
            case .denied: noToken(.refused)
            default: break
            }
        }
    }
}

/// iOS may call these on a queue of its own rather than the main thread, and
/// UIKit asserts that a tap's completion handler is called on the main
/// thread. So each takes iOS's completion handler, is `nonisolated` (a
/// main-actor one would trap when called from iOS's queue, as would
/// `MainActor.assumeIsolated`), reads what it needs where it is called, and
/// finishes on the main actor, calling the handler there on every path.
/// The `async` variants left it to Swift's bridging where the handler was
/// called: off the main thread, tapping a notice killed the app (TestFlight,
/// 2026-11-16; test/native_notice_isolation_test.rb).
extension PushRegistration: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let done = NoticeCompletion { completionHandler([.banner, .list, .sound, .badge]) }
        Task { @MainActor in done.call() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification = response.notification
        let tap = NoticeTap(userInfo: notification.request.content.userInfo,
                            action: response.actionIdentifier,
                            text: (response as? UNTextInputNotificationResponse)?.userText,
                            notificationId: notification.request.identifier,
                            deliveredAt: notification.date)
        let done = NoticeCompletion(call: completionHandler)
        Task { @MainActor in
            await self.respond(to: tap, answer: NotificationActions.answer)
            done.call()
        }
    }
}
