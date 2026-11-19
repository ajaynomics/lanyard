import HotwireNative
import SwiftUI

/// The app's own screen when a page can't load (HotwireConfig.makeCustomErrorView):
/// offline, the server out of reach, signed out or a failing page, each in
/// plain words (ErrorCopy), with one button to try again. Signed out, trying
/// again is signing in: the page's 401 opens the sign-in sheet (SceneController).
/// System colours and text styles, so dark mode and Dynamic Type follow.
struct ErrorScreen: ErrorPresentableView {
    let error: HotwireNativeError
    let handler: ErrorPresenter.Handler?

    var body: some View {
        let copy = ErrorCopy(statusCode: error.statusCode, urlError: Self.code(of: error), network: Self.isNetwork(error))
        ContentUnavailableView {
            Label(copy.title, systemImage: copy.symbol)
        } description: {
            Text(copy.message)
        } actions: {
            if let handler {
                Button(copy.action, action: handler)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("error-retry")
            }
        }
    }

    /// The connection error's code, from iOS or, when Turbo.js reported it, from its raw code.
    private static func code(of error: HotwireNativeError) -> URLError.Code? {
        if let code = error.urlError?.code { return code }
        if case .web(let web) = error { return URLError.Code(rawValue: web.errorCode) }
        return nil
    }

    private static func isNetwork(_ error: HotwireNativeError) -> Bool {
        if case .web = error { return true }
        return false
    }
}
