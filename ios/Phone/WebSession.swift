import Foundation
import WebKit

/// Requests to Rails carrying the person's web session, for the few things
/// the app asks Rails itself (TokenMint, PushRegistration, NotificationActions). The
/// cookies stay on the phone: they are copied from WebKit's store into each
/// request's headers, on an ephemeral session that keeps nothing, follows no
/// redirect and logs nothing.
@MainActor
final class WebSession {
    struct Answer {
        let status: Int
        let body: Data
    }

    private let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// How many of the install's cookies the phone holds: none, signed out.
    func cookieCount() async -> Int {
        await cookies().count
    }

    /// Sends the request with the session's cookies. Nil: no cookies (signed
    /// out), or no answer at all.
    func send(_ request: URLRequest) async throws -> Answer? {
        let cookies = await cookies()
        guard !cookies.isEmpty else { return nil }
        var request = request
        request.httpShouldHandleCookies = false
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (body, response) = try await session.data(for: request, delegate: RefuseRedirects())
        return Answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
    }

    /// Forgets the person here: every cookie and cached page in WebKit's
    /// store, which Hotwire Native's web views and these requests share.
    static func forget() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// The web view's own cookies. Hotwire Native (HotwireConfig) builds each
    /// web view from a plain WKWebViewConfiguration, sharing a process pool
    /// but not setting a data store, so its store is the default one.
    private func cookies() async -> [HTTPCookie] {
        guard let host = base.host() else { return [] }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
    }
}

/// A redirect is Rails sending a browser to a page: never followed.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
