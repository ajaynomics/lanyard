import Foundation
import os

private let log = Logger(subsystem: "org.durableassistants", category: "phone-push")

/// The phone app's notifications, by Apple's push service. Turning them on
/// starts on the web's Settings, Notifications (its Turn on asks iOS through the
/// notification-token component). This keeps the token iOS gives and posts it
/// to Rails itself each time iOS gives it (at launch, on each return to the
/// app, after Turn on) and after each sign-in, so it follows the person using
/// the phone. It also opens the page a tapped notice names (NotificationRouter). Rails
/// sends nothing until the install has an APNs key (docs/native-app.md).
/// Asking iOS and showing notices: PushRegistration+Notices.swift.
@MainActor
final class PushRegistration: NSObject {
    static let shared = PushRegistration()

    /// Where a tapped notice goes: SceneController opens it in its tab.
    let router = NotificationRouter(base: baseURL)
    /// Why iOS gave no token: permission refused, or registration failed.
    enum NoToken: String, Error { case refused, failed }
    /// Who waits for the token iOS gives next, or why none came (NotificationTokenFallback).
    private var waiting: [(Result<String, NoToken>) -> Void] = []

    /// Sends a request to Rails with the person's web session and gives the
    /// answer's HTTP status: nil signed out. A test records the requests
    /// instead (PushRegistrationTests).
    var send: @MainActor (URLRequest) async throws -> Int? = { request in
        try await WebSession(base: baseURL).send(request)?.status
    }

    /// The token iOS last gave, to post again after a sign-in (registerAgain).
    static var storedToken: String? {
        get { UserDefaults.standard.string(forKey: "apnsDeviceToken") }
        set { UserDefaults.standard.set(newValue, forKey: "apnsDeviceToken") }
    }

    /// iOS gave the token: Rails gets it now. Before, only a fresh sign-in
    /// sent it, so a phone already signed in never did (TestFlight, 2026-11-15).
    /// The post's task, for a test to wait on.
    @discardableResult
    func received(_ deviceToken: Data) -> Task<Void, Never> {
        let token = DeviceToken.hex(deviceToken)
        Self.storedToken = token
        log.notice("device token received")
        answer(.success(token))
        return Task { await register(token) }
    }

    /// iOS refused permission, or failed to register: whoever waits hears why,
    /// so the page says so. Before, a Turn on tap then waited for ever. Rails
    /// hears it too, with iOS's error code (Push::Attempt): the page can't say
    /// which, and before nobody could tell a refusal from a tap that never
    /// reached the app (production, 2026-11-15). The post's task, for a test.
    @discardableResult
    func noToken(_ reason: NoToken, code: Int? = nil) -> Task<Void, Never> {
        log.error("no device token: \(reason.rawValue, privacy: .public) \(code ?? 0)")
        answer(.failure(reason))
        return Task {
            do {
                let status = try await send(PhoneRequests.reportAttempt(base: baseURL, outcome: reason.rawValue, code: code))
                log.notice("no-token outcome reported: HTTP \(status ?? 0)")
            } catch {
                log.error("no-token outcome report failed \((error as NSError).code)")
            }
        }
    }

    /// Calls back with the token iOS gives next, as hex, or why none came.
    func nextToken(_ handler: @escaping (Result<String, NoToken>) -> Void) {
        waiting.append(handler)
    }

    private func answer(_ result: Result<String, NoToken>) {
        let waiting = waiting
        self.waiting = []
        waiting.forEach { $0(result) }
    }

    /// After a sign-in: the phone's token now belongs to whoever signed in.
    func registerAgain() async {
        guard let token = Self.storedToken else { return }
        await register(token)
    }

    /// Rails takes the same token again without harm (Push::DevicesController).
    private func register(_ token: String) async {
        do {
            let status = try await send(PhoneRequests.registerDevice(base: baseURL, token: token))
            log.notice("device token registered: HTTP \(status ?? 0)")
        } catch {
            log.error("device token registration failed \((error as NSError).code)")
        }
    }

    /// A notice's tap or button, as the notification delegate read it from
    /// iOS (PushRegistration+Notices.swift), on the main actor: a button
    /// answers in the background (NotificationActions) and returns only once
    /// that is done; a tap on the notice opens its page, now or once
    /// SceneController can (NotificationRouter). A test answers with a
    /// stand-in (NoticeTapTests).
    func respond(to tap: NoticeTap, answer answering: @MainActor (NoticeAnswer) async -> Void) async {
        if let answer = tap.route?.answer(to: tap.action, text: tap.text, notificationId: tap.notificationId, deliveredAt: tap.deliveredAt) {
            await answering(answer)
            return
        }
        router.route(tap.url)
    }
}

/// A tap or a button as iOS hands it to the delegate, read where iOS calls
/// it (not always the main thread) into values that may cross to the main
/// actor: iOS's response and its payload may not.
struct NoticeTap: Sendable {
    let route: NoticeRoute?
    let url: String?
    let action: String
    let text: String?
    let notificationId: String
    let deliveredAt: Date

    init(userInfo: [AnyHashable: Any], action: String, text: String?, notificationId: String, deliveredAt: Date) {
        route = NoticeRoute(userInfo: userInfo)
        url = userInfo["url"] as? String
        self.action = action
        self.text = text
        self.notificationId = notificationId
        self.deliveredAt = deliveredAt
    }
}
