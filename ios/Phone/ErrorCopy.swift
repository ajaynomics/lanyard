import Foundation

/// What the app's error screen says (ErrorScreen), from what went wrong:
/// offline, the server out of reach, signed out, or the page itself failing.
/// Plain words, with the way out on the button.
struct ErrorCopy: Equatable {
    let symbol: String
    let title: String
    let message: String
    let action: String

    /// `network`: the page never answered (a connection error, whatever its code).
    init(statusCode: Int?, urlError: URLError.Code?, network: Bool = false) {
        switch (statusCode, urlError) {
        case (401?, _):
            self.init("person.crop.circle.badge.questionmark", "Signed out",
                      "Sign in to see your agents.", "Sign in")
        case (404?, _):
            self.init("questionmark.folder", "Not found",
                      "This page has gone, or was never here.", "Try again")
        case (let status?, _) where status >= 500:
            self.init("exclamationmark.triangle", "Something went wrong",
                      "Lanyard couldn't load this page. Try again in a moment.", "Try again")
        case (_, .notConnectedToInternet?), (_, .networkConnectionLost?), (_, .dataNotAllowed?):
            self.init("wifi.slash", "You're offline",
                      "Connect to the internet, then try again.", "Try again")
        case (_, .timedOut?), (_, .cannotConnectToHost?), (_, .cannotFindHost?), (_, .dnsLookupFailed?):
            self.init("bolt.horizontal.circle", "Can't reach Lanyard",
                      "The server isn't answering. Try again in a moment.", "Try again")
        case (nil, _) where network:
            self.init("bolt.horizontal.circle", "Can't reach Lanyard",
                      "The server isn't answering. Try again in a moment.", "Try again")
        default:
            self.init("exclamationmark.triangle", "Something went wrong",
                      "Lanyard couldn't load this page.", "Try again")
        }
    }

    private init(_ symbol: String, _ title: String, _ message: String, _ action: String) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }
}
