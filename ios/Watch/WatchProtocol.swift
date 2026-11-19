import Foundation

// The Watch's requests to Rails, made with its own token, and what Rails'
// answers mean. Compiled into the Watch app and the unit tests.

/// What the Watch asks Rails for. Each case is one fixed Rails path, as JSON.
enum WatchRequest: Sendable, Equatable {
    case list
    /// A thread's newest turns, or those before an entry (Conversation::Transcript).
    case thread(conversationId: Int, before: Int?)
    case decide(conversationId: Int, invocationId: Int, decision: Decision, version: String)
    case send(conversationId: Int, text: String, requestId: String)

    /// A request that may change something if it arrives, so a lost answer
    /// leaves its outcome unknown rather than failed.
    var changesSomething: Bool {
        switch self {
        case .list, .thread: false
        case .decide, .send: true
        }
    }

    /// Which request, for the logs: never its words.
    var kind: String {
        switch self {
        case .list: "list"
        case .thread: "thread"
        case .decide: "decide"
        case .send: "send"
        }
    }

    /// The request as Rails takes it: JSON, with the Watch's token as a Bearer
    /// and no cookie (docs/design.md, "The Watch, with its own token").
    func urlRequest(base: URL, token: String) -> URLRequest {
        var request: URLRequest
        switch self {
        case .list:
            request = URLRequest(url: base.appendingPathComponent("conversations.json"))
        case let .thread(conversationId, before):
            let url = base.appendingPathComponent("conversations/\(conversationId)/messages.json")
            request = URLRequest(url: before.map { url.appending(queryItems: [URLQueryItem(name: "before", value: String($0))]) } ?? url)
        case let .decide(conversationId, invocationId, decision, version):
            request = Self.post(base.appendingPathComponent("conversations/\(conversationId)/invocations/\(invocationId)/approval.json"),
                                ["decision": decision.rawValue, "version": version])
        case let .send(conversationId, text, requestId):
            request = Self.post(base.appendingPathComponent("conversations/\(conversationId)/submissions.json"),
                                ["content": text, "request_id": requestId])
        }
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func post(_ url: URL, _ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum Decision: String, Sendable {
    case approve
    case deny
}

extension WatchRequest {
    /// A notice's button, as the Watch's own card or composer would ask it.
    init?(_ answer: NoticeAnswer) {
        switch answer {
        case let .decide(conversationId, invocationId, asked, version):
            guard let decision = Decision(rawValue: asked) else { return nil }
            self = .decide(conversationId: conversationId, invocationId: invocationId, decision: decision, version: version)
        case let .reply(conversationId, text, requestId):
            self = .send(conversationId: conversationId, text: text, requestId: requestId)
        }
    }
}

/// How far a request got. Only `answered` carries Rails' own answer.
enum Transport: Sendable, Equatable {
    /// Rails answered, with this status and body.
    case answered(status: Int, body: Data)
    /// It never reached Rails: nothing happened.
    case notSent(reason: String)
    /// It may have reached Rails, but its answer was lost.
    case unconfirmed(reason: String)
}

// A new decoder each time: a shared one would be shared mutable state.
enum WatchCoding {
    /// Rails writes snake_case.
    static var rails: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

// MARK: - Rails' JSON (docs/design.md, "The Watch, with its own token")

struct AgentRow: Codable, Sendable, Hashable, Identifiable {
    let conversationId: Int
    let name: String
    var id: Int { conversationId }
}

struct CardField: Codable, Sendable, Hashable {
    let label: String
    let text: String?
}

/// A waiting approval (Invocation::Card): every word the person decides on,
/// and the version that names exactly those words.
struct Card: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let conversationId: Int
    let agent: String
    let title: String
    let recipients: [String]
    let fields: [CardField]
    let note: String?
    let state: String
    let decision: String?
    let version: String
    let expiresAt: String?
    /// Small enough to allow on the Watch; a larger card is answered on the phone.
    let small: Bool
    let error: String?
}

struct Listing: Codable, Sendable, Equatable {
    let agents: [AgentRow]
    let approvals: [Card]
}

/// One turn of a thread, as plain words: the person's (`user`) or the agent's (`assistant`).
struct ThreadMessage: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let role: String
    let text: String
    let at: String

    var fromPerson: Bool { role == "user" }
}

/// A thread's newest turns (Conversation::Transcript). `earlier` is the entry
/// the page above ends before; nil at the start of the thread.
struct ThreadPage: Codable, Sendable, Equatable {
    let conversationId: Int
    let agent: String
    let messages: [ThreadMessage]
    let earlier: Int?
}

struct Acceptance: Codable, Sendable, Equatable {
    let conversationId: Int
    let requestId: String
    let accepted: Bool
}

// MARK: - What an answer means, failing closed

enum ListOutcome: Equatable, Sendable {
    case loaded(Listing)
    case signedOut
    case failed(String)

    init(_ transport: Transport) {
        switch transport {
        case .answered(200, let body):
            if let listing = try? WatchCoding.rails.decode(Listing.self, from: body) { self = .loaded(listing) }
            else { self = .failed("The answer could not be read.") }
        case .answered(401, _): self = .signedOut
        case .answered(let status, _): self = .failed("The server answered \(status).")
        case .notSent(let reason), .unconfirmed(let reason): self = .failed(reason)
        }
    }
}

enum ThreadOutcome: Equatable, Sendable {
    case loaded(ThreadPage)
    case signedOut
    /// Not found: not the person's, or gone.
    case gone
    case failed(String)

    init(_ transport: Transport) {
        switch transport {
        case .answered(200, let body):
            if let transcript = try? WatchCoding.rails.decode(ThreadPage.self, from: body) { self = .loaded(transcript) }
            else { self = .failed("The answer could not be read.") }
        case .answered(401, _): self = .signedOut
        case .answered(404, _): self = .gone
        case .answered(let status, _): self = .failed("The server answered \(status).")
        case .notSent(let reason), .unconfirmed(let reason): self = .failed(reason)
        }
    }
}

enum Refusal: String, Sendable {
    /// The card changed since it was shown: show it again before answering.
    case changed
    /// Too long to allow on the Watch.
    case phoneOnly = "phone_only"
    /// Someone answered it first, or it ran out of time.
    case answeredOrExpired = "answered_or_expired"
}

enum DecisionOutcome: Equatable, Sendable {
    /// Rails recorded this answer to this card.
    case decided(Card)
    case refused(Refusal, Card)
    case signedOut
    /// Nothing was recorded.
    case failed(String)
    /// It may have been recorded. Asking again with the same answer and
    /// version is safe: the same answer again is the answer already given.
    case unconfirmed(String)

    init(_ transport: Transport, asked decision: Decision) {
        switch transport {
        case .answered(200, let body):
            if let card = try? WatchCoding.rails.decode(Card.self, from: body), card.decision == decision.rawValue {
                self = .decided(card)
            } else {
                self = .unconfirmed("The answer did not confirm the decision.")
            }
        case .answered(409, let body):
            if let card = try? WatchCoding.rails.decode(Card.self, from: body), let refusal = card.error.flatMap(Refusal.init(rawValue:)) {
                self = .refused(refusal, card)
            } else {
                self = .failed("The server refused it.")
            }
        case .answered(401, _): self = .signedOut
        case .answered(let status, _) where status >= 500: self = .unconfirmed("The server failed (\(status)).")
        case .answered(let status, _): self = .failed("The server answered \(status).")
        case .notSent(let reason): self = .failed(reason)
        case .unconfirmed(let reason): self = .unconfirmed(reason)
        }
    }
}

enum SendOutcome: Equatable, Sendable {
    /// The agent's server accepted the message under this id. Not a reply.
    case accepted(requestId: String)
    case signedOut
    case failed(String)
    /// It may have been accepted. Sending again with the same id and words is
    /// the same message, never a second one.
    case unconfirmed(String)

    init(_ transport: Transport, requestId: String) {
        switch transport {
        case .answered(202, let body):
            if let acceptance = try? WatchCoding.rails.decode(Acceptance.self, from: body), acceptance.accepted, acceptance.requestId == requestId {
                self = .accepted(requestId: requestId)
            } else {
                self = .unconfirmed("The answer did not confirm the message.")
            }
        case .answered(401, _): self = .signedOut
        case .answered(let status, _) where status >= 500: self = .unconfirmed("The agent may not have it (\(status)).")
        case .answered(let status, _): self = .failed("The server answered \(status).")
        case .notSent(let reason): self = .failed(reason)
        case .unconfirmed(let reason): self = .unconfirmed(reason)
        }
    }
}

/// A new id for a new message: the edit of a message is a new message.
/// Rails accepts letters, digits, `_ . : -`, up to 128 (Agent::Access.valid_id?).
func newRequestId() -> String { "watch-\(UUID().uuidString.lowercased())" }
