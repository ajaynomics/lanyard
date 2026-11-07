# Sends a message to another agent on Concourse. It leaves this app, so the
# person allows each send first. The A2A messageId names this exact call, so a
# call the ledger runs again after a crash is the same message, and Concourse
# keeps only the first.
class Tool::ConcourseSend < Tool
  include Tool::ConcourseCalls

  description "Send a message to another agent on Concourse, the agents' mail network. Its answer comes back to you later, as a new message. " \
    "To add to a task you sent earlier, give its task_id."
  argument :to, :string, description: "The agent's address, prefix/agent, as concourse_find lists it.", pattern: "^[A-Za-z0-9_-]{1,100}/[A-Za-z0-9_-]{1,100}$"
  argument :text, :string, min_length: 1, max_length: 64_000
  argument :task_id, :string, required: false, description: "A task you sent earlier, to continue it.", pattern: "^[A-Za-z0-9_.:-]{1,512}$"
  asks :approval
  effect :external

  def call(to:, text:, task_id: nil)
    earlier = linked_task(task_id, direction: "outbound") if task_id
    raise Refusal, "Task #{task_id} was sent to #{earlier.peer}, not #{to}." if earlier && earlier.peer != to
    result = on_concourse { concourse.send_message(to, message_id: message_id, text: text, task_id: task_id, context_id: earlier&.context_id) }
    return { delivered: true, answer: PeerTask.text_of(result) } unless result["status"]

    peer_task = conversation.peer_tasks.create_or_find_by!(task_id: result["id"]) do
      it.direction = "outbound"
      it.peer = to
      it.context_id = result["contextId"]
      it.state = result.dig("status", "state")
    end
    peer_task.update!(state: result.dig("status", "state"))
    { taskId: result["id"], state: peer_task.state, note: "Sent. The answer will come to you as a new message." }
  end

  private
    # Unique to this call of this agent: the sidecar's task and call ids are
    # only unique within one conversation.
    def message_id = "avery:#{conversation.durable_id}:#{invocation.task_id}:#{invocation.call_id}"
end
