import HotwireNative
import UserNotifications

/// This check never prompts or asks APNs for a token. Both builds read the
/// same permission before handing Turn on to their token component.
final class NotificationStatusComponent: BridgeComponent {
    override nonisolated class var name: String { "notification-status" }

    override func onReceive(message: Message) {
        guard message.event == "read" else { return }
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status = settings.authorizationStatus == .denied ? "denied" : "available"
            self?.reply(with: message.replacing(data: State(status: status)), completion: nil)
        }
    }

    private struct State: Encodable {
        let status: String
    }
}
