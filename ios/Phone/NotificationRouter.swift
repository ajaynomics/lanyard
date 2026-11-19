import Foundation

/// Where a tapped notice goes, and when. iOS may hand the app a tap before
/// it has tabs to open it in (a cold launch from the banner), or while it is
/// signed out; and a cold launch only learns it is signed out when its first
/// page answers 401 (SessionGate starts signed in). So the page waits here
/// until a page of the current tabs has loaded without a 401, and is opened
/// once. Only a page of this install opens (DeepLink): a payload naming
/// another host, a relative path or nothing opens nothing.
@MainActor
final class NotificationRouter {
    private let base: URL
    /// SceneController's: opens a page in its tab, or says it can't yet.
    private var open: (@MainActor (DeepLink) -> Bool)?
    /// The last tap not yet opened: a newer tap replaces it.
    private(set) var pending: DeepLink?
    /// A page of the current tabs loaded signed in, so a page opened now
    /// will not be refused for want of a sign-in.
    private var signedIn = false

    /// Nonisolated, so PushRegistration can make one as it is made.
    nonisolated init(base: URL) {
        self.base = base
    }

    /// A tapped notice's `url`, as Rails sent it (Push::Device).
    func route(_ url: String?) {
        guard let link = DeepLink(path: url, base: base) else { return }
        pending = link
        openPending()
    }

    /// SceneController can open pages from now on.
    func ready(open: @escaping @MainActor (DeepLink) -> Bool) {
        self.open = open
        openPending()
    }

    /// Fresh tabs (at launch, after signing in or out): whether they are
    /// signed in is known only once their first page answers.
    func tabsBuilt() {
        signedIn = false
    }

    /// A page loaded while the app was not waiting on a sign-in: a held tap
    /// opens now. After a sign-in this is the rebuilt tabs' first page.
    func pageLoaded() {
        signedIn = true
        openPending()
    }

    /// Taken before it is opened, so it opens once.
    private func openPending() {
        guard signedIn, let open, let link = pending else { return }
        pending = nil
        if !open(link) { pending = link }
    }
}
