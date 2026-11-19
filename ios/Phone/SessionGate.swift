import Foundation

/// Whether the app is signed in, as its tabs see it, and when to rebuild
/// them (SceneController). One sign-in is acted on once: a page's 401 starts
/// a wait, the first page past the sign-in pages ends it, and nothing else
/// does. The tabs are never rebuilt twice within `minimumGap`, so even a
/// slip elsewhere can't spin.
struct SessionGate {
    enum Phase: Equatable {
        case signedIn
        case awaitingSignIn
    }

    enum Verdict: Equatable {
        /// An ordinary page: let Hotwire Native show it.
        case proceed
        /// The sign-in just succeeded: close the sheet, rebuild the tabs.
        case signedIn
    }

    /// What a page that failed calls for: only a 401 is signing in; any
    /// other failure (refused, timed out, no such host, a 5xx) is the error
    /// screen and Try again, never a wait.
    enum Failure: Equatable {
        case askToSignIn
        case showError
    }

    static let minimumGap: TimeInterval = 1

    static func failed(statusCode: Int?) -> Failure {
        statusCode == 401 ? .askToSignIn : .showError
    }

    private(set) var phase: Phase = .signedIn
    private var lastRebuild: Date?

    /// A page answered 401: waiting on the sign-in sheet. True if it starts a wait.
    mutating func refused() -> Bool {
        guard phase == .signedIn else { return false }
        phase = .awaitingSignIn
        return true
    }

    /// A page the app is about to show. While waiting, the first one past the
    /// sign-in pages (Rails' refresh after signing in, or where it sent the
    /// app) is the sign-in succeeding, once; every later one is a page.
    mutating func proposed(path: String) -> Verdict {
        guard phase == .awaitingSignIn, !Self.isSigningIn(path) else { return .proceed }
        phase = .signedIn
        return .signedIn
    }

    /// The browser sheet (NativeSignIn) signed the person in.
    mutating func signedInThroughBrowserSheet() {
        phase = .signedIn
    }

    /// Whether the tabs may be rebuilt now; records it if so.
    mutating func mayRebuild(at now: Date) -> Bool {
        if let lastRebuild, now.timeIntervalSince(lastRebuild) < Self.minimumGap { return false }
        lastRebuild = now
        return true
    }

    static func isSigningIn(_ path: String) -> Bool {
        ["/sign_in", "/auth/", "/native_sign_in", "/development_session"].contains { path.hasPrefix($0) }
    }
}
