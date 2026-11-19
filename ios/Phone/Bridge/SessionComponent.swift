import HotwireNative
import UIKit

/// Signing out from the Settings tab, which is the web's /settings
/// (settings/_native_rows; web side: app/javascript/native/session_controller.js).
/// By the time the page says so, Rails has ended the session, revoked the
/// Watch's tokens and forgotten this iPhone's notifications token. What is
/// left is the app's: its cookies, the Watch, the badges and tabs that start
/// afresh, signed out (SceneController). No library component knows a
/// session, so this one is the app's.
final class SessionComponent: BridgeComponent {
    override nonisolated class var name: String { "session" }

    static let signedOut = Notification.Name("LanyardSignedOut")

    override func onReceive(message: Message) {
        guard message.event == "signed-out" else { return }
        NotificationCenter.default.post(name: Self.signedOut, object: nil)
    }
}
