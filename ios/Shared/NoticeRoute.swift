import Foundation
import UserNotifications

// A notice's buttons and where it leads, for the phone and the Watch alike
// (docs/design.md, "A notice's buttons"). Rails names each notice's buttons by
// its category and sends the ids and the card's version an answer needs
// (Conversation::Notifiable::Buttons, Push::Device). The buttons are only
// what the Watch's own card and composer offer: Allow once on a small card,
// Decline on any other approval, Reply on a reply. Never Always.

/// The categories Rails sends, in `aps.category`. The same strings as Rails'.
enum NoticeCategory: String, Sendable, CaseIterable {
    /// A small approval card: Allow once or Decline.
    case approval = "APPROVAL"
    /// Any other approval card: Decline only; allowing it needs the phone's card.
    case needsYou = "NEEDS_YOU"
    /// An agent's finished reply: Reply, with words.
    case reply = "REPLY"
}

/// The buttons' identifiers, as iOS and watchOS hand them back.
enum NoticeAction: String, Sendable, CaseIterable {
    case allowOnce = "ALLOW_ONCE"
    case decline = "DECLINE"
    case reply = "REPLY"
}

/// The buttons each category shows. On the phone a button answers in the
/// background, and Reply asks for words in the notice itself. On the Watch
/// each opens the app, which says what Rails answered: watchOS drops the words
/// typed into a forwarded notice's own text field, so Reply opens the
/// composer, with dictation and Scribble.
enum NoticeCategories {
    static var all: Set<UNNotificationCategory> {
        // Answering for the person needs the device unlocked.
        #if os(watchOS)
        let options: UNNotificationActionOptions = [.authenticationRequired, .foreground]
        let reply = UNNotificationAction(identifier: NoticeAction.reply.rawValue, title: "Reply", options: options)
        #else
        let options: UNNotificationActionOptions = [.authenticationRequired]
        let reply = UNTextInputNotificationAction(identifier: NoticeAction.reply.rawValue, title: "Reply", options: options,
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        #endif
        let allow = UNNotificationAction(identifier: NoticeAction.allowOnce.rawValue, title: "Allow once", options: options)
        let decline = UNNotificationAction(identifier: NoticeAction.decline.rawValue, title: "Decline", options: options.union(.destructive))
        return [
            UNNotificationCategory(identifier: NoticeCategory.approval.rawValue, actions: [allow, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: NoticeCategory.needsYou.rawValue, actions: [decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: NoticeCategory.reply.rawValue, actions: [reply], intentIdentifiers: [])
        ]
    }
}

/// What a button asks Rails: the same JSON the Watch's card and composer send.
enum NoticeAnswer: Equatable, Sendable {
    /// `decision` is "approve" or "deny", as Rails takes it.
    case decide(conversationId: Int, invocationId: Int, decision: String, version: String)
    case reply(conversationId: Int, text: String, requestId: String)

    /// The page that shows it, for a tap on a notice saying it was not done:
    /// the card, or the thread.
    var path: String {
        switch self {
        case let .decide(_, invocationId, _, _): "/approvals/\(invocationId)"
        case let .reply(conversationId, _, _): "/conversations/\(conversationId)"
        }
    }

    var conversationId: Int {
        switch self {
        case let .decide(conversationId, _, _, _), let .reply(conversationId, _, _): conversationId
        }
    }
}

/// One notice as Rails sent it: its category, its thread, and for a card the
/// card and the version the person saw.
struct NoticeRoute: Equatable, Sendable {
    let category: NoticeCategory?
    let conversationId: Int
    let invocationId: Int?
    let version: String?

    /// Nil for a notice with no thread (one Rails sent before #78, say).
    init?(userInfo: [AnyHashable: Any]) {
        guard let conversationId = Self.int(userInfo["conversation_id"]) else { return nil }
        self.conversationId = conversationId
        invocationId = Self.int(userInfo["invocation_id"])
        version = (userInfo["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        category = (aps?["category"] as? String).flatMap(NoticeCategory.init(rawValue:))
    }

    init(category: NoticeCategory?, conversationId: Int, invocationId: Int?, version: String?) {
        self.category = category
        self.conversationId = conversationId
        self.invocationId = invocationId
        self.version = version
    }

    /// What a button asks Rails, or nil: a tap on the notice itself, a button
    /// this notice's category does not have, or a card with no version. Allow
    /// once only on a small card, Decline only on a card, Reply only on a
    /// reply and only with words.
    func answer(to action: String, text: String?, notificationId: String, deliveredAt: Date) -> NoticeAnswer? {
        switch (NoticeAction(rawValue: action), category) {
        case (.allowOnce?, .approval?):
            return decide("approve")
        case (.decline?, .approval?), (.decline?, .needsYou?):
            return decide("deny")
        case (.reply?, .reply?):
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .reply(conversationId: conversationId, text: text,
                          requestId: Self.requestId(notificationId: notificationId, deliveredAt: deliveredAt))
        default:
            return nil
        }
    }

    /// One id per notice, so the same answer delivered twice is one message.
    /// A notice's identifier is its thread's (Rails collapses a thread's
    /// notices into one), so the time it arrived tells two notices apart.
    /// Rails takes letters, digits, `_ . : -`, up to 128
    /// (Agent::Access.valid_id?).
    static func requestId(notificationId: String, deliveredAt: Date) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        let safe = String(String.UnicodeScalarView(notificationId.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        return String("notice-\(Int(deliveredAt.timeIntervalSince1970))-\(safe)".prefix(128))
    }

    private func decide(_ decision: String) -> NoticeAnswer? {
        guard let invocationId, let version else { return nil }
        return .decide(conversationId: conversationId, invocationId: invocationId, decision: decision, version: version)
    }

    /// APNs JSON numbers arrive as NSNumber; a string of digits is taken too.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

/// What the phone says when a button's answer was not done, or nil when Rails
/// confirmed it: the same reading of Rails' answer as the Watch's
/// (DecisionOutcome, SendOutcome), failing closed. Shown as a notice of its
/// own, whose tap opens the card or the thread.
enum NoticeReceipt {
    static let signedOut = "Signed out on this iPhone. Open Lanyard to sign in."
    static let lost = "Not confirmed: the answer was lost on the way. Open it to check."

    /// `status` nil: no answer with the session (signed out).
    static func problem(_ answer: NoticeAnswer, status: Int?, body: Data) -> String? {
        guard let status else { return signedOut }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch (answer, status) {
        case let (.decide(_, _, decision, _), 200):
            return json?["decision"] as? String == decision ? nil : "Not confirmed. Open it to check."
        case (.decide, 409):
            switch json?["error"] as? String {
            case "changed": return "It changed since this notice. Open it to read it again."
            case "phone_only": return "Too long to allow from a notice. Open it to answer."
            case "answered_or_expired": return "Already answered, or it expired."
            default: return "Not done: the server refused it."
            }
        case let (.reply(_, _, requestId), 202):
            return json?["accepted"] as? Bool == true && json?["request_id"] as? String == requestId ? nil : "Not confirmed. Open the thread to check."
        case (_, 401):
            return signedOut
        case (_, 500...):
            return "Not confirmed: the server failed (\(status)). Open it to check."
        default:
            return "Not sent: the server answered \(status)."
        }
    }
}
