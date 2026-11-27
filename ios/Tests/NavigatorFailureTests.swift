import HotwireNative
import UIKit
import XCTest

/// A page that fails to load reaches SceneController's visitableDidFailRequest,
/// which opens the sign-in sheet on a 401. Hotwire Native's NavigatorDelegate
/// is nonisolated, and SceneController a main-actor type: it conforms
/// `@preconcurrency`, as this stand-in does, so Swift checks at run time that
/// Hotwire Native calls it on the main actor. This target is Swift 6, where the
/// plain conformance does not compile. SceneController itself needs the app
/// (UIKit's scene), so the build Mac's log shows its conformance (BUILD.md).
final class NavigatorFailureTests: XCTestCase {
    /// The path a failed page takes: Hotwire Native's Navigator, told by its
    /// Session, passes the failure and a retry to its delegate.
    @MainActor
    func testAFailedPageReachesTheDelegateOnTheMainActorWithARetry() {
        let delegate = FailedPages()
        let navigator = Navigator(configuration: .init(name: "failures", startLocation: page), delegate: delegate)
        let visitable = VisitableViewController(url: page)

        navigator.session(navigator.session, didFailRequestForVisitable: visitable, error: .http(.client(.unauthorized)))

        XCTAssertEqual(delegate.statusCodes, [401])
        XCTAssertEqual(delegate.onMain, [true])
        XCTAssertEqual(delegate.retryable, [true], "the error screen's button tries the page again")
    }
}

private let page = URL(string: "https://app.example.com/approvals")!

/// Declared as SceneController's conformance is.
@MainActor
private final class FailedPages: @preconcurrency NavigatorDelegate {
    var statusCodes: [Int?] = []
    var onMain: [Bool] = []
    var retryable: [Bool] = []

    func visitableDidFailRequest(_ visitable: Visitable, error: HotwireNativeError, retryHandler: RetryBlock?) {
        MainActor.assertIsolated("Hotwire Native reports a failed page on the main actor")
        statusCodes.append(error.statusCode)
        onMain.append(Thread.isMainThread)
        retryable.append(retryHandler != nil)
    }
}
