import AuthenticationServices
import os
import UIKit
import WebKit

/// What signing in did, for `log show` (BUILD.md). Steps and outcomes only:
/// never a code, verifier or cookie.
let signInLog = Logger(subsystem: "org.durableassistants", category: "native-sign-in")

/// The app's own URL scheme, from the build (NATIVE_SIGN_IN_SCHEME, by default
/// the bundle id), which the install's Rails must name too
/// (APP__NATIVE_SIGN_IN_SCHEME). Schemes ignore case; Rails writes it lower.
let nativeSignInScheme: String = {
    let configured = (Bundle.main.object(forInfoDictionaryKey: "NativeSignInScheme") as? String)?.lowercased() ?? ""
    return configured.isEmpty ? "org.durableassistants.companion" : configured
}()

/// Signing in the way identity providers allow a native app to: in a browser
/// sheet (ASWebAuthenticationSession, Safari's own browser, where Google and
/// passkeys work), not in the app's web view, which they refuse. The sheet
/// signs in at the provider and comes back to the app's own address with a
/// one-time code; the app posts the code and its PKCE verifier from a web
/// view of its own, and Rails answers with the ordinary session cookie, which
/// lands in WebKit's default store, the one Hotwire Native's web views and
/// TokenMint read (TESTFLIGHT.md, "Signing in inside the app").
@MainActor
final class NativeSignIn: NSObject {
    enum Outcome: Equatable {
        /// Signed in; the page Rails sent the app to.
        case signedIn(URL)
        /// The person closed the sheet.
        case cancelled
        /// Rails refused the code: expired, used, or not this app's.
        case refused
        case failed
    }

    private let base: URL
    private let scheme: String
    private let anchor: () -> UIWindow?
    /// Kept until it finishes: a sheet whose session is released closes.
    private var authentication: ASWebAuthenticationSession?
    private var redemption: Redemption?

    init(base: URL, scheme: String, anchor: @escaping () -> UIWindow?) {
        self.base = base
        self.scheme = scheme
        self.anchor = anchor
    }

    var isRunning: Bool { authentication != nil || redemption != nil }

    /// Opens the sheet, then finishes in the app. One at a time: a second tap
    /// while the sheet is open does nothing.
    func start(completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        guard !isRunning else { return }
        let request = NativeSignInRequest()
        // Sendable, so not the main actor's: the sheet may call it from its own queue.
        let returned: ASWebAuthenticationSession.CompletionHandler = { @Sendable [weak self] callback, error in
            Task { @MainActor in await self?.returned(callback, error: error, request: request, completion: completion) }
        }
        let session: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            session = ASWebAuthenticationSession(url: request.startURL(base: base), callback: .customScheme(scheme), completionHandler: returned)
        } else {
            session = ASWebAuthenticationSession(url: request.startURL(base: base), callbackURLScheme: scheme, completionHandler: returned)
        }
        session.presentationContextProvider = self
        // Safari's own sign-ins (Google, passkeys, the provider's) are wanted:
        // they are what make signing in work here.
        session.prefersEphemeralWebBrowserSession = false
        authentication = session
        guard session.start() else {
            signInLog.error("the sheet did not open")
            authentication = nil
            completion(.failed)
            return
        }
        signInLog.notice("sheet opened")
    }

    private func returned(_ callback: URL?, error: Error?, request: NativeSignInRequest,
                          completion: @MainActor (Outcome) -> Void) async {
        authentication = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            signInLog.notice("sheet closed by the person")
            return completion(.cancelled)
        }
        guard let callback, let code = NativeSignInRequest.code(from: callback, scheme: scheme) else {
            signInLog.error("sheet came back without a code, error=\((error as NSError?)?.code ?? 0)")
            return completion(.failed)
        }
        signInLog.notice("sheet came back with a code")
        let redemption = Redemption()
        self.redemption = redemption
        let outcome = await redemption.load(request.redemption(base: base, code: code))
        self.redemption = nil
        signInLog.notice("redeemed: \(String(describing: outcome), privacy: .public)")
        completion(outcome)
    }
}

extension NativeSignIn: ASWebAuthenticationPresentationContextProviding {
    // Asked on the main thread, by the sheet as it opens.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor() ?? ASPresentationAnchor() }
    }
}

/// Posts the code and verifier in a web view of the app's own, off screen,
/// sharing WebKit's default store with Hotwire Native's, so the session cookie
/// Rails sets is the app's. Rails answers a good code with a redirect to the
/// start page and a refused one with its own page at /native_sign_in.
@MainActor
private final class Redemption: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var finished: CheckedContinuation<NativeSignIn.Outcome, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ request: URLRequest) async -> NativeSignIn.Outcome {
        await withCheckedContinuation { continuation in
            finished = continuation
            webView.load(request)
        }
    }

    private func finish(_ outcome: NativeSignIn.Outcome) {
        finished?.resume(returning: outcome)
        finished = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return finish(.failed) }
        let path = url.path()
        let refused = path == NativeSignInRequest.redeemPath || path == "/sign_in"
        finish(refused ? .refused : .signedIn(url))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        signInLog.error("redeem failed \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        finish(.failed)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        signInLog.error("redeem failed \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        finish(.failed)
    }
}
