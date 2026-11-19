# How a helper the agent started in the background is getting on, from what
# the sidecar last reported (Helper): working or how it ended, and its latest
# calls. Only one of this conversation's. Offered with helpers.
class Tool::CheckHelper < Tool
  description "See how a helper you started in the background (subagent with background: true) is getting on: " \
    "whether it is still working, how many calls it has made, and its latest ones."
  argument :helper, :string, min_length: 1, max_length: 200, description: "The id of the subagent call that started the helper."

  LATEST = 8

  # The agent's own helper in this conversation by its call, or a refusal.
  def self.find(conversation, call_id)
    conversation.helpers.own.find_by(call_id: call_id) or
      raise Refusal, "No helper you started with that call is in this conversation."
  end

  def call(helper:)
    found = self.class.find(conversation, helper)
    { state: found.state, task: found.task, calls: found.call_count,
      latest: Array(found.calls).last(LATEST).map { it.slice("name", "status") },
      answer: (found.answer if found.done?), reason: (found.why if found.failed?) }.compact
  end
end
