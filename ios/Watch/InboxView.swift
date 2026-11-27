import SwiftUI

/// The cards waiting for the person, then their agents, each opening its
/// thread. A notice opens its card or thread here too (NoticeDesk).
struct InboxView: View {
    @EnvironmentObject private var inbox: Inbox
    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var desk: NoticeDesk

    var body: some View {
        NavigationStack(path: $desk.path) {
            List {
                switch inbox.outcome {
                case .loaded(let listing) where phone.token != nil:
                    Section("Waiting") {
                        if listing.approvals.isEmpty { Text("Nothing waiting").foregroundStyle(.secondary) }
                        ForEach(listing.approvals) { card in
                            NavigationLink(value: card) {
                                VStack(alignment: .leading) {
                                    Text(card.title).lineLimit(2)
                                    // Which call: two cards can share a title.
                                    if let first = card.fields.first?.text {
                                        Text(first).font(.footnote).lineLimit(1)
                                    }
                                    Text(card.agent).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Write to") {
                        ForEach(listing.agents) { agent in
                            NavigationLink(agent.name, value: agent)
                                .accessibilityIdentifier("agent:\(agent.name)")
                        }
                    }
                case .failed(let reason) where phone.token != nil:
                    Text("Couldn't load. \(reason)").foregroundStyle(.red)
                case nil where phone.token != nil:
                    EmptyView()
                default:
                    Text(Reconnect.message)
                }
                Button(inbox.loading ? "Loading…" : "Refresh") {
                    Task { await inbox.refresh() }
                }
                .disabled(inbox.loading || phone.token == nil)
            }
            .navigationTitle("Agents")
            .navigationDestination(for: Card.self) { CardView(card: $0) }
            .navigationDestination(for: AgentRow.self) { ThreadView(agent: $0) }
            .navigationDestination(for: Reply.self) { ComposeView(agent: $0.agent) }
        }
        .sheet(item: $desk.answered) { answered in
            ScrollView {
                Text(answered.words).foregroundStyle(answered.done ? Color.green : Color.orange)
            }
        }
        .task { await inbox.refresh() }
        // A notice's button answered a card: the list shows what still waits.
        .onChange(of: desk.answered?.id) { _, answered in
            if answered != nil { Task { await inbox.refresh() } }
        }
        // A token arriving from the phone loads the list once.
        .onChange(of: phone.token) { old, new in
            if old == nil, new != nil { Task { await inbox.refresh() } }
        }
    }
}

/// What the Watch says without a token, or once Rails refused it.
enum Reconnect {
    static let message = "Open Ajent on your iPhone to reconnect."
}
