import HotwireNative
import UIKit
import UserNotifications

/// How many cards wait on the person, from any page (layouts/_badge, kept
/// current by Rails' broadcasts): the badge on the tab the page names and on
/// the app's icon. Set here, on the tabs the page is in or is a sheet over
/// (AppTabBarController). The app's own; no library component sets a tab's
/// badge (web side: app/javascript/native/tab_badge_controller.js).
final class TabBadgeComponent: BridgeComponent {
    override nonisolated class var name: String { "tab-badge" }

    override func onReceive(message: Message) {
        guard message.event == "set", let badge: TabBadge = message.data() else { return }
        (delegate?.destination as? UIViewController)?.hostingTabs?.showBadge(badge)
        UNUserNotificationCenter.current().setBadgeCount(badge.count)
    }
}
