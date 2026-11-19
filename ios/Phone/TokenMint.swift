import Foundation

/// Asks Rails for a Watch's own token (POST /watches.json), over the person's
/// web session (WebSession): the one request the phone makes for the Watch.
@MainActor
final class TokenMint {
    enum Outcome: Equatable {
        case minted(String)
        /// Not signed in on the phone yet.
        case signedOut
        case failed(String)
    }

    private let base: URL
    private let web: WebSession

    init(base: URL) {
        self.base = base
        web = WebSession(base: base)
    }

    func token(forWatchNamed name: String) async -> Outcome {
        var request = URLRequest(url: base.appendingPathComponent("watches.json"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // As the web app's own page would send it: Rails' forgery check asks
        // for it over https (docs/design.md, "The Watch, with its own token").
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        let cookies = await web.cookieCount()
        handoffLog.notice("cookies for the server: \(cookies)")
        guard cookies > 0 else { return .signedOut }
        do {
            guard let answer = try await web.send(request) else { return .signedOut }
            handoffLog.notice("token asked: HTTP \(answer.status)")
            switch answer.status {
            case 201:
                let body = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
                guard let token = body?["token"] as? String, !token.isEmpty else { return .failed("unreadable answer") }
                return .minted(token)
            case 401: return .signedOut
            default: return .failed("HTTP \(answer.status)")
            }
        } catch {
            handoffLog.error("token request failed \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return .failed("no answer")
        }
    }
}
