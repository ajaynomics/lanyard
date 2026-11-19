import SwiftUI

/// A short message to one agent, from its thread or a notice's Reply. Sent once under its request id; sending the
/// same words again keeps the id, so the agent gets one message. Changing the
/// words makes a new message with a new id.
struct ComposeView: View {
    let agent: AgentRow

    @State private var text = Self.prefill
    @State private var requestId = newRequestId()
    @State private var outcome: SendOutcome?
    @State private var inFlight = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Message", text: $text)
                    .onChange(of: text) { _, _ in
                        // An edit is a new message, never a resend of the old one.
                        requestId = newRequestId()
                        outcome = nil
                    }
                    .disabled(inFlight || accepted)
                status
                if accepted {
                    Button("New message") { text = "" }
                } else {
                    Button(buttonTitle) { send() }
                        .disabled(inFlight || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(agent.name)
    }

    /// UI tests cannot type on a Watch simulator, so in a debug build they
    /// start the box with words (LANYARD_UI_TEST_MESSAGE). Sending is the same.
    nonisolated private static var prefill: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["LANYARD_UI_TEST_MESSAGE"] ?? ""
        #else
        ""
        #endif
    }

    private var accepted: Bool {
        if case .accepted = outcome { return true }
        return false
    }

    private var buttonTitle: String {
        if case .unconfirmed = outcome { return "Send again" }
        return "Send"
    }

    @ViewBuilder private var status: some View {
        switch outcome {
        case .accepted:
            Text("Accepted. \(agent.name.isEmpty ? "The agent" : agent.name) has it; its reply shows in the thread.").foregroundStyle(.green)
        case .signedOut:
            Text(Reconnect.message).foregroundStyle(.red)
        case .failed(let reason):
            Text("Not sent. \(reason)").foregroundStyle(.red)
        case .unconfirmed(let reason):
            Text("Not confirmed. \(reason) Send again to ask with the same message.").foregroundStyle(.orange)
        case nil:
            if inFlight { ProgressView() }
        }
    }

    private func send() {
        let words = text
        let id = requestId
        inFlight = true
        outcome = nil
        Task {
            let transport = await Rails.send(.send(conversationId: agent.conversationId, text: words, requestId: id))
            outcome = SendOutcome(transport, requestId: id)
            inFlight = false
        }
    }
}
