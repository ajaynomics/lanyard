import HotwireNative
import os
import UIKit

private let log = Logger(subsystem: "org.durableassistants", category: "phone-push")

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Which pages are sheets and which push (docs/native-app.md): the
        // bundled copy at once, then Rails' own, which may be newer. ios_v3:
        // the Settings tab is the web's /settings, with no screen of the app's own.
        Hotwire.loadPathConfiguration(from: [
            .file(Bundle.main.url(forResource: "path-configuration", withExtension: "json")!),
            .server(baseURL.appendingPathComponent("configurations/ios_v3.json"))
        ])
        Hotwire.registerBridgeComponents(Components.all)
        // Each sheet's close button is the app's own, at the leading edge
        // (WebViewController): Hotwire Native's Done, on the right, gave way to
        // a form's submit and left the sheet with no way out.
        Hotwire.config.defaultViewController = { url in WebViewController(url: url) }
        Hotwire.config.backButtonDisplayMode = .minimal
        // A thread fills the screen, its composer at the foot: no tab bar under it.
        Hotwire.config.hideTabBarWhenPushed = true
        Hotwire.config.makeCustomErrorView = { error, handler in ErrorScreen(error: error, handler: handler) }
        // Tells the web's sign-in page this app signs in through its own
        // browser sheet (NativeSignIn), so the page offers that; and Rails
        // which of Apple's push services this build's token is for, and which
        // build this is, for what became of Turn on (Push::Attempt).
        Hotwire.config.applicationUserAgentPrefix = "NativeSignIn/1; APNs/\(DeviceToken.environment); Lanyard/\(AppVersion.current);"
        // Opaque bars, so a pushed page starts below the title bar. With
        // see-through bars (iOS 26) its first row sat under the bar and could
        // not be tapped: Settings' You, and so Sign out (seen on the M4).
        let opaque = UINavigationBarAppearance()
        opaque.configureWithOpaqueBackground()
        UINavigationBar.appearance().standardAppearance = opaque
        UINavigationBar.appearance().scrollEdgeAppearance = opaque
        UINavigationBar.appearance().isTranslucent = false
        // From launch, so a Watch's ask for a token, kept by WatchConnectivity
        // until this app runs, is heard.
        WatchHandoff.shared.start()
        PushRegistration.shared.start()
        #if DEBUG
        NoticeTapFixture.scheduleIfAsked()
        #endif
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Components.deliver(deviceToken)
        PushRegistration.shared.received(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("remote notification registration failed \((error as NSError).code)")
        PushRegistration.shared.noToken(.failed, code: (error as NSError).code)
    }
}
