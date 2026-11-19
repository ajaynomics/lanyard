#if !BRIDGE_COMPONENTS_PRO
import HotwireNative
import UIKit
import UserNotifications

/// The public build's notification-token component, for builds without Bridge
/// Components Pro (whose own component the Pro build uses). It answers the
/// same messages, so the web's bridge--notification-token controller, from
/// the public bridge-components npm package, works with either: on `get` it
/// asks iOS to allow notifications and replies with the device token, as
/// lower-case hex, once iOS gives it (PushRegistration). If iOS refuses
/// permission or fails to register, it replies with an empty token and why
/// (`error`: refused or failed), so the page says so at once. The web's
/// controller passes on only `token`, so the page can't tell which; the app
/// tells Rails itself (PushRegistration.noToken).
final class NotificationTokenFallback: BridgeComponent {
    override nonisolated class var name: String { "notification-token" }

    override func onReceive(message: Message) {
        guard message.event == "get" else { return }
        PushRegistration.shared.nextToken { [weak self] result in
            switch result {
            case .success(let token): self?.reply(to: "get", with: Token(token: token, error: nil))
            case .failure(let reason): self?.reply(to: "get", with: Token(token: "", error: reason.rawValue))
            }
        }
        Task {
            let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if allowed { UIApplication.shared.registerForRemoteNotifications() } else { PushRegistration.shared.noToken(.refused) }
        }
    }

    private struct Token: Encodable {
        let token: String
        let error: String?
    }
}
#endif
