import BridgeComponents
import Foundation
import HotwireNative
#if BRIDGE_COMPONENTS_PRO
import BridgeComponentsPro
#endif

/// Every bridge component the app answers (docs/native-app.md), registered
/// once: Hotwire Native keeps only the last list it is given.
///
/// Bridge Components' own (MIT, public) for the bar's buttons, menus, form
/// submits, alerts, haptics and sharing. With the Pro package on the
/// build Mac (BUILD.md, "Bridge Components Pro"), its notification-token
/// component asks iOS for notifications; a public build uses the app's own
/// NotificationTokenFallback, which speaks the same messages. Approval,
/// tab-badge and session have no library equivalent, so they are the app's; so is the
/// toast (NoticeComponent), as VoiceOver can't read the library's, nor a UI test find it,
/// and the Agents list's search (NativeSearchComponent), under a name only a checked build answers.
enum Components {
    static var all: [BridgeComponent.Type] {
        library + notificationToken + [NotificationStatusComponent.self, LocationComponent.self, ApprovalComponent.self,
                                       TabBadgeComponent.self, NoticeComponent.self, SessionComponent.self,
                                       NativeSearchComponent.self]
    }

    /// Bridge Components' own, but the toast: the app's NoticeComponent
    /// speaks the same messages, and VoiceOver and UI tests can find it.
    private static var library: [BridgeComponent.Type] {
        Bridgework.coreComponents.filter { $0.name != NoticeComponent.name }
    }

    #if BRIDGE_COMPONENTS_PRO
    private static let notificationToken: [BridgeComponent.Type] = [NotificationTokenComponent.self]
    #else
    private static let notificationToken: [BridgeComponent.Type] = [NotificationTokenFallback.self]
    #endif

    /// The token iOS gave, for Pro's component, as its documentation asks.
    /// AppDelegate hands it over; the fallback waits on PushRegistration instead.
    static func deliver(_ deviceToken: Data) {
        #if BRIDGE_COMPONENTS_PRO
        Bridgework.post(.didReceiveNotificationToken, deviceToken)
        #endif
    }
}
