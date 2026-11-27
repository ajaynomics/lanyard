import Foundation

/// The requests the phone app makes to Rails itself, beside its web views,
/// built without sending, so they can be checked without a network
/// (PhoneRequestsTests). Each carries the person's web session, added by
/// WebSession.
enum PhoneRequests {
    /// This phone's notifications token, for whoever is signed in
    /// (Push::DevicesController). Sent again after each sign-in, so the token
    /// follows the person using the phone, and each time the app comes to the
    /// front with notifications allowed. No time: Rails keeps the report it
    /// receives last, this or a refusal, whatever the phone's clock says.
    static func registerDevice(base: URL, token: String, environment: String = DeviceToken.environment) -> URLRequest {
        var request = json("POST", base.appendingPathComponent("push/devices.json"), body: form([URLQueryItem(name: "token", value: token)]))
        // Which of Apple's services the token is for, as the web view's own user agent says it.
        request.setValue("Lanyard APNs/\(environment)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Why iOS gave this phone no token (Push::AttemptsController): refused
    /// or failed, with iOS's error code, so whoever runs the install can see
    /// it. The page can't: the web's notification-token controller passes on
    /// only the token. Never the token itself. A refusal also comes each time
    /// the app comes to the front with notifications off in the iPhone's
    /// Settings.
    static func reportAttempt(base: URL, outcome: String, code: Int?, version: String = AppVersion.current) -> URLRequest {
        var items = [URLQueryItem(name: "outcome", value: outcome)]
        if let code { items.append(URLQueryItem(name: "code", value: String(code))) }
        var request = json("POST", base.appendingPathComponent("push/attempts.json"), body: form(items))
        request.setValue("Lanyard/\(version) APNs/\(DeviceToken.environment)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A notice's button answered on the phone (NoticeAnswer): the same JSON
    /// the Watch's card and composer send, with the person's web session, so
    /// Rails holds it to the Watch's card: the version the notice named, Allow
    /// once only on a small card, never Always.
    static func answer(base: URL, _ answer: NoticeAnswer) -> URLRequest {
        switch answer {
        case let .decide(conversationId, invocationId, decision, version):
            return jsonBody(base.appendingPathComponent("conversations/\(conversationId)/invocations/\(invocationId)/approval.json"),
                            ["decision": decision, "version": version])
        case let .reply(conversationId, text, requestId):
            return jsonBody(base.appendingPathComponent("conversations/\(conversationId)/submissions.json"),
                            ["content": text, "request_id": requestId])
        }
    }

    struct LocationFix: Encodable {
        let latitude: Double
        let longitude: Double
        let accuracy_m: Double
        let timestamp: Date
    }

    static func locationResult(base: URL, conversation: String, invocation: String, outcome: String, fix: LocationFix?) -> URLRequest? {
        guard let conversationId = Int64(conversation), conversationId > 0,
              let invocationId = Int64(invocation), invocationId > 0 else { return nil }
        let url = base.appendingPathComponent("conversations/\(conversationId)/invocations/\(invocationId)/location_request.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(LocationResult(outcome: outcome, location_fix: fix)) else { return nil }
        var request = json("PATCH", url, body: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private struct LocationResult: Encodable {
        let outcome: String
        let location_fix: LocationFix?
    }

    private static func json(_ method: String, _ url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // As the web app's own page would send it: Rails' forgery check asks
        // for it over https (as TokenMint's).
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.httpBody = body
        return request
    }

    /// A person's words go as JSON: a form body would need its own escaping.
    private static func jsonBody(_ url: URL, _ body: [String: String]) -> URLRequest {
        var request = json("POST", url, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func form(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

/// A device token as Rails keeps it: lower-case hex.
enum DeviceToken {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Which of Apple's two push services this build's token is for: a
    /// development-signed build gets the sandbox's. Rails reads it from the
    /// web view's user agent (APNs/…), to send each token to its own service.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

/// This build's version and build number, as "0.1(12)": Rails reads it from
/// a user agent's Lanyard/… (Push::Attempt#app_version).
enum AppVersion {
    static var current: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version)(\(build))"
    }
}

/// Where a tapped notification goes: the page its payload names
/// (Push::Device), on this install only, in the tab that holds it, among the
/// tabs Rails serves (SceneController).
struct DeepLink: Equatable, Sendable {
    let url: URL

    init?(userInfo: [AnyHashable: Any], base: URL) {
        self.init(path: userInfo["url"] as? String, base: base)
    }

    /// A path on this install, resolved against its address: never a full
    /// URL, a protocol-relative one (`//host/...`) or a path without its slash.
    init?(path: String?, base: URL) {
        guard let path, path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host() == base.host(), url.port == base.port else { return nil }
        self.url = url
    }
}
