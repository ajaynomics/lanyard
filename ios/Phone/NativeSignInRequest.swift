import CryptoKit
import Foundation

/// One sign-in through the browser sheet, as addresses and requests: what the
/// sheet opens, what the app accepts back, and what it posts to finish. PKCE,
/// as OAuth does for a native app (RFC 7636, RFC 8252): the sheet carries only
/// the challenge, the SHA-256 of a secret verifier that never leaves this
/// object until the app posts it with the code. No UI and no network here, so
/// the unit tests cover all of it (Tests/NativeSignInTests.swift).
struct NativeSignInRequest: Sendable, Equatable {
    /// Where the web's sign-in page sends the phone app (its "Sign in" link).
    static let startPath = "/native_sign_in/new"
    /// Where the app posts the code and verifier to get its session.
    static let redeemPath = "/native_sign_in"
    /// The host of the app's own address the sheet comes back to.
    static let returnHost = "signed-in"

    let verifier: String

    init(verifier: String = NativeSignInRequest.randomVerifier()) {
        self.verifier = verifier
    }

    /// 32 random bytes, base64url: 43 characters, as RFC 7636 asks.
    /// SystemRandomNumberGenerator is the system's secure generator.
    static func randomVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func challenge(of verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    var challenge: String { Self.challenge(of: verifier) }

    /// Whether a page the web proposes is the sign-in the app runs itself.
    static func isStart(_ url: URL, base: URL) -> Bool {
        url.host() == base.host() && url.port == base.port && url.path() == startPath
    }

    /// What the browser sheet opens.
    func startURL(base: URL) -> URL {
        var components = URLComponents(url: base.appending(path: String(Self.startPath.dropFirst())), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    /// The one-time code from the address the sheet came back to, if that is
    /// the app's own (`<scheme>://signed-in?code=…`).
    static func code(from callback: URL, scheme: String) -> String? {
        guard callback.scheme?.lowercased() == scheme.lowercased(), callback.host() == returnHost,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    /// The post that trades the code and the verifier for a session, loaded
    /// in a web view so the session's cookie lands in WebKit's store.
    func redemption(base: URL, code: String) -> URLRequest {
        var request = URLRequest(url: base.appending(path: String(Self.redeemPath.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("code=\(Self.formEncoded(code))&code_verifier=\(Self.formEncoded(verifier))".utf8)
        return request
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
