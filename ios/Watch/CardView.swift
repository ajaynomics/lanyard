import SwiftUI

/// One waiting call, every word of it, and Allow once or Decline. Says
/// "Allowed" or "Declined" only when Rails confirms it.
struct CardView: View {
    @EnvironmentObject private var inbox: Inbox
    let card: Card

    @State private var asked: Decision?
    @State private var outcome: DecisionOutcome?
    @State private var inFlight = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.agent).font(.footnote).foregroundStyle(.secondary)
                Text(card.title).font(.headline)
                if !card.recipients.isEmpty {
                    Text("To: \(card.recipients.joined(separator: ", "))")
                }
                ForEach(card.fields, id: \.self) { field in
                    VStack(alignment: .leading) {
                        Text(field.label).font(.footnote).foregroundStyle(.secondary)
                        Text(field.text ?? "Open on your iPhone to read this.")
                    }
                }
                if let note = card.note { Text(note).font(.footnote) }

                status
                actions
            }
        }
        .navigationTitle("Waiting")
    }

    @ViewBuilder private var status: some View {
        switch outcome {
        case .decided(let decided):
            Text(decided.decision == "approve" ? "Allowed." : "Declined.").foregroundStyle(.green)
        case .refused(.changed, _):
            Text("This changed since it was shown. Go back and refresh to read it again.").foregroundStyle(.orange)
        case .refused(.phoneOnly, _):
            Text("Too long to allow here. Answer it on your iPhone.").foregroundStyle(.orange)
        case .refused(.answeredOrExpired, let current):
            Text(current.decision.map { "Already answered: \($0 == "approve" ? "allowed" : "declined")." } ?? "This has expired.")
                .foregroundStyle(.orange)
        case .signedOut:
            Text(Reconnect.message).foregroundStyle(.red)
        case .failed(let reason):
            Text("Not sent. \(reason)").foregroundStyle(.red)
        case .unconfirmed(let reason):
            Text("Not confirmed. \(reason) Check again to ask with the same answer.").foregroundStyle(.orange)
        case nil:
            if inFlight { ProgressView() }
        }
    }

    @ViewBuilder private var actions: some View {
        switch outcome {
        case .decided, .refused:
            EmptyView()
        case .unconfirmed:
            // The same answer and version again: Rails records it once.
            if let asked {
                Button("Check again") { decide(asked) }.disabled(inFlight)
            }
        default:
            if card.small {
                Button("Allow once") { decide(.approve) }.disabled(inFlight)
            } else {
                Text("Allow this on your iPhone.").font(.footnote)
            }
            Button("Decline", role: .destructive) { decide(.deny) }.disabled(inFlight)
        }
    }

    private func decide(_ decision: Decision) {
        asked = decision
        inFlight = true
        outcome = nil
        Task {
            let transport = await Rails.send(.decide(conversationId: card.conversationId, invocationId: card.id,
                                                     decision: decision, version: card.version))
            let decided = DecisionOutcome(transport, asked: decision)
            outcome = decided
            inFlight = false
            decided.haptic.play()
            if case .decided = outcome { await inbox.refresh() }
        }
    }
}
