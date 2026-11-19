import SwiftUI

/// Opens the composer for one agent, from its thread or a notice's Reply.
struct Reply: Hashable {
    let agent: AgentRow
}

/// One agent's thread: its newest turns as plain words, earlier ones on
/// demand, then Reply. Read straight from Rails with the Watch's token, and
/// read again each time it shows; reading it here leaves it unread on the
/// phone.
struct ThreadView: View {
    let agent: AgentRow

    @State private var outcome: ThreadOutcome?
    /// Turns loaded from earlier pages, oldest first, above the newest page.
    @State private var earlierMessages: [ThreadMessage] = []
    @State private var earlier: Int?
    @State private var loading = false

    var body: some View {
        List {
            switch outcome {
            case .loaded(let page):
                if let earlier {
                    Button(loading ? "Loading…" : "Earlier") { loadEarlier(before: earlier) }.disabled(loading)
                }
                if page.messages.isEmpty && earlierMessages.isEmpty {
                    Text("Nothing here yet").foregroundStyle(.secondary)
                }
                ForEach(earlierMessages + page.messages) { message in
                    VStack(alignment: .leading) {
                        Text(message.fromPerson ? "You" : page.agent).font(.footnote).foregroundStyle(.secondary)
                        Text(message.text)
                    }
                }
            case .signedOut:
                Text(Reconnect.message)
            case .gone:
                Text("This thread is not here any more.").foregroundStyle(.secondary)
            case .failed(let reason):
                Text("Couldn't load. \(reason)").foregroundStyle(.red)
            case nil:
                ProgressView()
            }
            NavigationLink("Reply", value: Reply(agent: agent))
                .accessibilityIdentifier("reply")
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(title)
        .task { await load() }
    }

    /// The agent's name from the thread itself: a notice opens it by id alone.
    private var title: String {
        if case .loaded(let page) = outcome { return page.agent }
        return agent.name
    }

    private func load() async {
        loading = true
        outcome = ThreadOutcome(await Rails.send(.thread(conversationId: agent.conversationId, before: nil)))
        earlierMessages = []
        if case .loaded(let page) = outcome { earlier = page.earlier } else { earlier = nil }
        loading = false
    }

    private func loadEarlier(before entry: Int) {
        loading = true
        Task {
            let older = ThreadOutcome(await Rails.send(.thread(conversationId: agent.conversationId, before: entry)))
            if case .loaded(let page) = older {
                earlierMessages = page.messages + earlierMessages
                earlier = page.earlier
            }
            loading = false
        }
    }
}
