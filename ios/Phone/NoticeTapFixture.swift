#if DEBUG
import Foundation
import UserNotifications

/// The UI test's notice (PhoneNoticeTapUITests), never in a release build:
/// launched with `-NoticeTapForUITests /approvals`, the app asks to show
/// notifications and schedules a local one naming that page, a few seconds
/// out. The test kills the app and taps the banner, so iOS itself launches it
/// and calls the notification delegate, as a tap on Apple's push would.
enum NoticeTapFixture {
    static let title = "Notice tap fixture"

    static func scheduleIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "NoticeTapForUITests") else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Opens \(path)"
            content.userInfo = ["url": path]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "notice-tap-fixture", content: content, trigger: trigger))
        }
    }
}
#endif
