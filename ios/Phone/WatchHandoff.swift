import Foundation
import os
import WatchConnectivity

/// What the handoff did, for `log show` (BUILD.md). Steps, states and status
/// codes only: never a cookie or the token.
let handoffLog = Logger(subsystem: "org.durableassistants", category: "phone-handoff")

/// The phone's end of WatchConnectivity, for one thing only: a Watch without
/// a token asks, and the phone, signed in, gets one from Rails (TokenMint)
/// and hands it over, once. The Watch makes every request itself.
/// Not main-actor isolated as a whole, as WatchConnectivity calls its
/// delegate on its own queue (as the earlier WatchRelay did); the state it
/// keeps is the main actor's.
final class WatchHandoff: NSObject, @unchecked Sendable {
    static let shared = WatchHandoff()

    @MainActor private lazy var mint = TokenMint(base: baseURL)
    @MainActor private var handing = false

    /// The asking Watch's name, kept until it has its token: across launches,
    /// and until the phone is signed in.
    @MainActor private var asking: String? {
        get { UserDefaults.standard.string(forKey: "watchAskingForToken") }
        set { UserDefaults.standard.set(newValue, forKey: "watchAskingForToken") }
    }

    func start() {
        guard WCSession.isSupported() else {
            handoffLog.error("WatchConnectivity not supported")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        handoffLog.notice("activating")
    }

    /// Gets and hands over a token if the Watch asked for one. Tried when it
    /// asks, when the app comes to the front and when a page finishes loading,
    /// so signing in on the phone completes it.
    @MainActor func handOver() async {
        guard let name = asking, !handing else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            handoffLog.notice("not handing over: state=\(session.activationState.rawValue) paired=\(session.isPaired) watchApp=\(session.isWatchAppInstalled)")
            return
        }
        handing = true
        defer { handing = false }
        switch await mint.token(forWatchNamed: name) {
        case .minted(let token):
            session.transferUserInfo(TokenHandoff.token(token).userInfo)
            asking = nil
            handoffLog.notice("token sent to the Watch")
        case .signedOut:
            handoffLog.notice("not signed in yet: the Watch waits")
        case .failed(let reason):
            handoffLog.error("no token: \(reason, privacy: .public)")
        }
    }

    /// Signed out on the phone: the Watch forgets its token, which Rails has
    /// revoked, and asks again, to be answered once someone signs in.
    @MainActor func signedOut() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        session.transferUserInfo(TokenHandoff.signedOut.userInfo)
        handoffLog.notice("told the Watch: signed out")
    }

    /// An ask sent while this app runs: answered with the token itself, or
    /// with nothing while signed out (the ask is kept for later).
    @MainActor func answer(askBy name: String) async -> [String: Any] {
        asking = name
        handoffLog.notice("the Watch asked for a token, by message")
        guard !handing else { return [:] }
        handing = true
        defer { handing = false }
        switch await mint.token(forWatchNamed: name) {
        case .minted(let token):
            asking = nil
            handoffLog.notice("token sent to the Watch, in reply")
            return TokenHandoff.token(token).userInfo
        case .signedOut:
            handoffLog.notice("not signed in yet: the Watch waits")
        case .failed(let reason):
            handoffLog.error("no token: \(reason, privacy: .public)")
        }
        return [:]
    }

    @MainActor private func asked(by name: String) {
        asking = name
        handoffLog.notice("the Watch asked for a token")
        Task { await handOver() }
    }
}

extension WatchHandoff: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        handoffLog.notice("activated state=\(activationState.rawValue) paired=\(session.isPaired) watchApp=\(session.isWatchAppInstalled) error=\((error as NSError?)?.code ?? 0)")
        Task { @MainActor in await self.handOver() }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard case .ask(let name)? = TokenHandoff(userInfo) else {
            handoffLog.error("received something other than an ask")
            return
        }
        Task { @MainActor in self.asked(by: name) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard case .ask(let name)? = TokenHandoff(message) else {
            handoffLog.error("received a message other than an ask")
            replyHandler([:])
            return
        }
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in reply(await self.answer(askBy: name)) }
    }

    // Installing the Watch app after the phone started shows here.
    func sessionWatchStateDidChange(_ session: WCSession) {
        handoffLog.notice("watch state paired=\(session.isPaired) watchApp=\(session.isWatchAppInstalled)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    // A new Watch paired: listen to it. Its own ask brings its own token.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
