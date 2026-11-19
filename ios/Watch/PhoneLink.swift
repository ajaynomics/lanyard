import Foundation
import os
import WatchConnectivity
import WatchKit

/// What the Watch's link to the phone did, for `log show` (BUILD.md). Steps,
/// states and status codes only: never the token.
private let log = Logger(subsystem: "org.durableassistants", category: "watch-link")

/// The Watch's link to the phone, for one thing only: getting the Watch's own
/// token (TokenHandoff). Every request goes to Rails directly (Rails).
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    static let shared = PhoneLink()

    private let store = TokenStore(base: baseURL)

    /// The token Rails made for this Watch. None: the Watch has asked the
    /// phone for one, which it gets when the phone's app next runs.
    @Published private(set) var token: String?

    func start() {
        token = store.read()
        log.notice("start token=\(self.token == nil ? "none" : "kept", privacy: .public)")
        guard WCSession.isSupported() else {
            log.error("WatchConnectivity not supported")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Rails refused this token (revoked, or unknown): forget it and ask the
    /// phone for a new one. A token received since is kept.
    func forget(_ refused: String) {
        guard token == refused else { return }
        let status = store.delete()
        token = nil
        log.notice("token refused, forgotten status=\(status)")
        ask()
    }

    /// Asks the phone for a token. While the phone's app is running, as a
    /// message it answers at once; and, one at a time, as a queued transfer
    /// WatchConnectivity keeps until the phone's app next runs.
    private func ask() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let ask = TokenHandoff.ask(watchName: WKInterfaceDevice.current().name)
        if session.isReachable {
            session.sendMessage(ask.userInfo, replyHandler: { @Sendable reply in
                guard case .token(let token)? = TokenHandoff(reply) else {
                    log.notice("the phone has no token yet")
                    return
                }
                Task { @MainActor in self.received(token) }
            }, errorHandler: { @Sendable error in
                log.notice("ask message failed code=\((error as NSError).code)")
            })
            log.notice("asked the phone for a token, by message")
        }
        if session.outstandingUserInfoTransfers.contains(where: { TokenHandoff($0.userInfo)?.kind == "ask" }) {
            log.notice("still waiting for the phone")
            return
        }
        session.transferUserInfo(ask.userInfo)
        log.notice("asked the phone for a token")
    }

    private func received(_ token: String) {
        guard token != self.token else { return }
        let status = store.save(token)
        if status == errSecSuccess {
            log.notice("token received")
        } else {
            // Kept for this run only, so a failing keychain shows in the log
            // rather than as a Watch that never connects.
            log.error("token received, keychain save failed status=\(status); kept until the app quits")
        }
        self.token = token
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        log.notice("activated state=\(activationState.rawValue) companion=\(session.isCompanionAppInstalled) error=\((error as NSError?)?.code ?? 0)")
        Task { @MainActor in
            if self.token == nil { self.ask() }
        }
    }

    // The phone's app came to the front: ask it directly.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.notice("reachable=\(session.isReachable)")
        guard session.isReachable else { return }
        Task { @MainActor in
            if self.token == nil { self.ask() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        switch TokenHandoff(userInfo) {
        case .token(let token)?:
            Task { @MainActor in self.received(token) }
        case .signedOut?:
            // Signed out on the phone: Rails revoked this token already.
            Task { @MainActor in if let token = self.token { self.forget(token) } }
        default:
            log.error("received something other than a token")
        }
    }
}
