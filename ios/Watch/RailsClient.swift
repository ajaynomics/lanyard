import Foundation
import os

/// What the Watch's requests did, for `log show` (BUILD.md). Kinds, status
/// codes and error codes only: never a body or the token.
private let log = Logger(subsystem: "org.durableassistants", category: "watch-rails")

/// The Watch's requests, straight to Rails with its own token (WatchRequest):
/// on an ephemeral session that keeps nothing, follows no redirect and gives
/// up after `patience`. Nothing is queued or sent again by itself.
struct RailsClient: Sendable {
    /// How long a request waits for Rails before it gives up.
    static let patience: TimeInterval = 20

    private let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = Self.patience
        configuration.timeoutIntervalForResource = Self.patience
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// One request and how far it got: Rails' answer, or plainly not sent,
    /// or sent with its answer lost. Always ends, within `patience`.
    func perform(_ request: WatchRequest, token: String) async -> Transport {
        log.notice("send \(request.kind, privacy: .public)")
        do {
            let (body, response) = try await session.data(for: request.urlRequest(base: base, token: token), delegate: RefuseRedirects())
            guard let http = response as? HTTPURLResponse else {
                log.error("\(request.kind, privacy: .public) no HTTP response")
                return lost(request, "No answer from the server.")
            }
            log.notice("\(request.kind, privacy: .public) HTTP \(http.statusCode) bytes=\(body.count)")
            return .answered(status: http.statusCode, body: body)
        } catch let error as URLError where Self.neverSent.contains(error.code) {
            log.error("\(request.kind, privacy: .public) URLError \(error.code.rawValue), not sent")
            return .notSent(reason: "The server can't be reached.")
        } catch {
            log.error("\(request.kind, privacy: .public) failed \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return lost(request, "The answer was lost on the way.")
        }
    }

    /// A read that got no answer plainly failed; a change may or may not have happened.
    private func lost(_ request: WatchRequest, _ reason: String) -> Transport {
        request.changesSomething ? .unconfirmed(reason: reason) : .notSent(reason: reason)
    }

    /// Failures that happen before a request leaves the Watch.
    private static var neverSent: Set<URLError.Code> {
        [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
         .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection]
    }
}

/// A redirect is Rails sending a browser to a page: never followed, so its
/// status reaches the Watch as what it is.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// The Watch's one way to Rails: its token if it has one. Without one, or
/// once Rails refuses it, nothing is sent and the Watch asks the phone for
/// another (PhoneLink). Rails refusing a token is the only thing that ends it.
@MainActor
enum Rails {
    private static let client = RailsClient(base: baseURL)

    static func send(_ request: WatchRequest) async -> Transport {
        // No token: as Rails would answer it, and nothing left the Watch.
        guard let token = PhoneLink.shared.token else { return .answered(status: 401, body: Data()) }
        let transport = await client.perform(request, token: token)
        if case .answered(401, _) = transport { PhoneLink.shared.forget(token) }
        return transport
    }
}
