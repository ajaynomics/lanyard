import SwiftUI

@main
struct WatchApp: App {
    @StateObject private var inbox = Inbox()

    init() {
        PhoneLink.shared.start()
        // Before launch ends, so a notice's button that opened the app is heard.
        NoticeDesk.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            InboxView()
                .environmentObject(inbox)
                .environmentObject(PhoneLink.shared)
                .environmentObject(NoticeDesk.shared)
        }
    }
}

/// What the Watch last heard from Rails: the agents to write to and the
/// cards waiting. Read again on demand; never answered from a stale copy.
@MainActor
final class Inbox: ObservableObject {
    @Published private(set) var outcome: ListOutcome?
    @Published private(set) var loading = false

    /// One load at a time: launch and a token arriving can both ask at once.
    func refresh() async {
        guard !loading else { return }
        loading = true
        let earlier = outcome?.listing
        outcome = ListOutcome(await Rails.send(.list))
        loading = false
        // A card that came in since the last look, as a notice would say.
        if outcome?.listing?.hasNewCards(since: earlier) == true { WatchHaptic.notification.play() }
    }
}
