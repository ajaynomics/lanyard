import HotwireNative
import os
import UIKit
import UserNotifications
import WebKit

/// The app's window: the tabs Rails serves, each its own stack of web pages
/// (AppTab, AppTabBarController),
/// and the sign-in sheet when Rails says nobody is signed in (a page's 401).
/// Signing in is the web's sign-in page, as a sheet, whose "Sign in" link, for
/// this app, starts the browser sheet (NativeSignIn); the session it ends with
/// lives in WebKit's cookies, on the phone (TESTFLIGHT.md, "Signing in inside
/// the app"). Signed in or out, the tabs start afresh.
///
/// Signed in within the sheet, Rails answers the app with Hotwire Native's
/// refresh (`/refresh_historical_location`, Authentication#start_session_for):
/// left to Hotwire Native, it would close the sheet and reload the page
/// beneath, whose 401 error screen stays and whose sibling tabs are not
/// signed in. Instead the app rebuilds its tabs. Through the browser sheet
/// (NativeSignIn) it rebuilds them when the sheet reports success. Signed out
/// from the Settings tab's page, Rails has done its part when the page says
/// so (SessionComponent); the app forgets its cookies and does the same.
private let sessionLog = Logger(subsystem: "org.durableassistants", category: "phone-session")

final class SceneController: UIResponder {
    var window: UIWindow?

    private var tabs: AppTabBarController?
    private lazy var nativeSignIn = NativeSignIn(base: baseURL, scheme: nativeSignInScheme) { [weak self] in self?.window }
    /// Signed in or waiting on the sign-in sheet; when the tabs may be rebuilt.
    private var gate = SessionGate()
    /// The UI tests' signed-out start clears the cookies once, at first launch.
    private static var clearedForUITests = false
    private var rebuildPending = false
    /// Whether the fresh tabs' first page has loaded or failed.
    private var firstVisit = FirstVisitWatch()
    private var signedOutObserver: NSObjectProtocol?
}

extension SceneController: UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        #if DEBUG
        // The walkthrough's look, light or dark, held for the whole run
        // (`-LanyardAppearance dark`): the simulator's own setting may still be
        // switching as the app launches. The web pages follow the window.
        switch UserDefaults.standard.string(forKey: "LanyardAppearance") {
        case "light": window?.overrideUserInterfaceStyle = .light
        case "dark": window?.overrideUserInterfaceStyle = .dark
        default: break
        }
        #endif
        window?.makeKeyAndVisible()
        signedOutObserver = NotificationCenter.default.addObserver(forName: SessionComponent.signedOut, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signedOut() }
        }
        // A notification tapped to launch the app opens once the tabs are
        // here and their first page has loaded signed in (requestDidFinish).
        PushRegistration.shared.router.ready { [weak self] link in self?.open(link) ?? false }
        #if DEBUG
        // The sheet's UI test starts signed out (BUILD.md). Never in a release build.
        if ProcessInfo.processInfo.arguments.contains("-SignedOutForUITests"), !Self.clearedForUITests {
            Self.clearedForUITests = true
            Task { @MainActor in
                await WebSession.forget()
                self.showTabs()
            }
            return
        }
        #endif
        showTabs()
    }

    // Back in the app: notifications may have been turned on in iOS Settings
    // meanwhile, and Rails may have lost the token; iOS gives it again.
    func sceneWillEnterForeground(_ scene: UIScene) {
        PushRegistration.shared.askForToken()
        refreshSettings()
    }

    // A Watch waiting for its token gets it once the app is open and signed in.
    func sceneDidBecomeActive(_ scene: UIScene) {
        Task { @MainActor in await WatchHandoff.shared.handOver() }
    }

    /// Fresh tabs: at launch, after signing in and after signing out, as the
    /// path configuration Hotwire Native holds lists them then (AppTab.served):
    /// a newer list from Rails shows the next time. Only the selected tab
    /// loads until another is chosen, so a signed-out start asks to sign in once.
    private func showTabs() {
        guard gate.mayRebuild(at: Date()) else {
            // Never twice within the gap: once more after it, at most.
            sessionLog.error("tabs asked for again within \(SessionGate.minimumGap)s: deferred")
            guard !rebuildPending else { return }
            rebuildPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(SessionGate.minimumGap))
                self?.rebuildPending = false
                self?.showTabs()
            }
            return
        }
        // A held notice waits for these tabs' first page: a 401 means a sign-in first.
        PushRegistration.shared.router.tabsBuilt()
        // Loading starts the selected tab's visit, which asks handle(proposal:)
        // at once: everything it reads is settled before.
        let tabs = AppTabBarController(tabs: AppTab.served(Hotwire.config.pathConfiguration.settings),
                                       base: baseURL, navigatorDelegate: self)
        self.tabs = tabs
        tabs.loadServedTabs()
        window?.rootViewController = tabs
        sessionLog.notice("tabs built")
        watchFirstVisit()
    }

    /// The first page must load or fail: past FirstVisitWatch's patience the
    /// error screen shows, whose Try again starts that same page afresh.
    private func watchFirstVisit() {
        let number = firstVisit.started(at: Date())
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(FirstVisitWatch.patience))
            guard let self, firstVisit.isOverdue(number, at: Date()), let tabs else { return }
            firstVisit.settled()
            let navigator = tabs.activeNavigator
            guard let page = navigator.rootViewController.topViewController as? (Visitable & UIViewController) else { return }
            sessionLog.error("first page neither loaded nor failed in \(FirstVisitWatch.patience)s: error screen")
            page.presentError(.web(WebError(urlError: URLError(.timedOut)))) { [weak self, weak navigator, weak page] in
                guard let page else { return }
                navigator?.session.visit(page, reload: true)
                self?.watchFirstVisit()
            }
        }
    }

    /// A tapped notification: its page, in the tab that holds it. False
    /// while there are no tabs or the app waits on a sign-in: NotificationRouter
    /// holds it until a page of the rebuilt tabs loads.
    private func open(_ link: DeepLink) -> Bool {
        guard let tabs, gate.phase == .signedIn else { return false }
        tabs.selectTab(tabs.served.holding(link.url.path()))
        tabs.activeNavigator.route(link.url)
        return true
    }

    /// The Settings tab says Notifications' and the Watch's status, which
    /// change outside it (iOS's Settings, the Watch): afresh on coming back to
    /// the front, now if it shows, else when it is next chosen, as the app's
    /// own screen did. Its sheet, if one is open, is left as it is.
    private func refreshSettings() {
        guard let tabs, let navigator = tabs.navigator(forTabID: "settings") else { return }
        if tabs.activeNavigator === navigator {
            navigator.session.reload()
        } else {
            navigator.session.markContentAsStale()
        }
    }
}

extension SceneController: NavigatorDelegate {
    func handle(proposal: VisitProposal, from navigator: Navigator) -> ProposalResult {
        if NativeSignInRequest.isStart(proposal.url, base: baseURL) {
            signIn()
            return .reject
        }
        // Waiting on a sign-in, the first page past the sign-in pages means it
        // succeeded (Rails' refresh, or a page it sent the app to), once.
        if gate.proposed(path: proposal.url.path()) == .signedIn {
            sessionLog.notice("signed in from the sheet (\(proposal.url.path(), privacy: .public)): fresh tabs")
            signedIn()
            return .reject
        }
        return .accept
    }

    func visitableDidFailRequest(_ visitable: Visitable, error: HotwireNativeError, retryHandler: RetryBlock?) {
        // Signed out: the sign-in sheet over the page, whose error screen's
        // button asks again if the sheet is closed.
        firstVisit.settled()
        sessionLog.notice("page failed (\(error.statusCode.map(String.init) ?? "no status", privacy: .public)): error screen")
        if SessionGate.failed(statusCode: error.statusCode) == .askToSignIn { askToSignIn() }
        (visitable as? ErrorPresenter)?.presentError(error, retryHandler: retryHandler)
    }

    // After each page, signing in included. A failed page finishes too, after
    // visitableDidFailRequest: a 401 has by then started the wait, so a held
    // notice opens only on a page that loaded signed in.
    func requestDidFinish(at url: URL) {
        firstVisit.settled()
        if gate.phase == .signedIn { PushRegistration.shared.router.pageLoaded() }
        Task { @MainActor in await WatchHandoff.shared.handOver() }
    }

    private func askToSignIn() {
        guard let tabs else { return }
        let navigator = tabs.activeNavigator
        guard navigator.rootViewController.presentedViewController == nil else { return }
        // Again too, if the sheet was closed without signing in.
        _ = gate.refused()
        sessionLog.notice("signed out: opening the sign-in sheet")
        // A sheet that can't be swiped away (PathConfiguration, /sign_in).
        navigator.route(baseURL.appendingPathComponent("sign_in"))
    }

    private func signIn() {
        nativeSignIn.start { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .signedIn:
                gate.signedInThroughBrowserSheet()
                signedIn()
            case .cancelled:
                break
            case .refused, .failed:
                let alert = UIAlertController(title: "Sign-in did not complete",
                                              message: "Nobody was signed in. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                window?.rootViewController?.topmost.present(alert, animated: true)
            }
        }
    }

    private func signedIn() {
        // Whatever is up, the sign-in sheet included, goes with the old tabs.
        window?.rootViewController?.dismiss(animated: false)
        showTabs()
        Task { @MainActor in
            await PushRegistration.shared.registerAgain()
            await WatchHandoff.shared.handOver()
        }
    }

    /// Rails has ended the session, revoked the Watch's tokens and forgotten
    /// this phone's notifications token (SessionsController#destroy): the
    /// cookies go here, the Watch forgets its token, and the tabs start afresh,
    /// whose first page's 401 opens the sign-in sheet.
    private func signedOut() {
        sessionLog.notice("signed out from Settings: fresh tabs")
        Task { @MainActor in
            await WebSession.forget()
            WatchHandoff.shared.signedOut()
            // The fresh tabs below start with no badge; the icon's goes here.
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            showTabs()
        }
    }
}

private extension UIViewController {
    /// Where an alert can show: over whatever sheet is up.
    var topmost: UIViewController { presentedViewController?.topmost ?? self }
}
