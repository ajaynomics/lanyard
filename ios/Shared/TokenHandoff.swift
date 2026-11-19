import Foundation

/// All the phone and the Watch say to each other, over WatchConnectivity's
/// sendMessage while the phone's app runs, else transferUserInfo: the Watch asks for a token, and the phone, signed in,
/// hands one over; signing out on the phone tells the Watch to forget its own.
/// Every request to Rails goes from the Watch itself
/// (docs/design.md, "The Watch, with its own token").
enum TokenHandoff: Equatable, Sendable {
    /// From the Watch: it has no token. Its name is for Settings to show.
    case ask(watchName: String)
    /// From the phone: the Watch's own token, made for it by Rails.
    case token(String)
    /// From the phone: the person signed out there (its Settings). Rails has
    /// revoked the Watch's token already; the Watch forgets it and asks again.
    case signedOut

    var userInfo: [String: Any] {
        switch self {
        case .ask(let name): ["ask": name]
        case .token(let token): ["token": token]
        case .signedOut: ["signedOut": true]
        }
    }

    init?(_ userInfo: [String: Any]) {
        if let token = userInfo["token"] as? String, !token.isEmpty {
            self = .token(token)
        } else if let name = userInfo["ask"] as? String {
            self = .ask(watchName: name)
        } else if userInfo["signedOut"] as? Bool == true {
            self = .signedOut
        } else {
            return nil
        }
    }

    /// Which message, for the logs: never the token.
    var kind: String {
        switch self {
        case .ask: "ask"
        case .token: "token"
        case .signedOut: "signedOut"
        }
    }
}
