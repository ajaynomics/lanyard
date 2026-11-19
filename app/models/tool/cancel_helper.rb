# The agent's Cancel for a helper it started in the background: the person's
# own (Helper#cancel), by the call that started it, and only one of this
# conversation's. Offered with helpers (the `subagents` capability).
class Tool::CancelHelper < Tool
  description "Stop a helper you started in the background (subagent with background: true) that is still working: " \
    "when its task is no longer needed or it has gone wrong. It stops at once; no answer comes from it."
  argument :helper, :string, min_length: 1, max_length: 200, description: "The id of the subagent call that started the helper."
  effect :external
  safe_to_repeat

  def call(helper:)
    # A helper has no helpers of its own (agent/subagent.mjs).
    raise Refusal, "A helper can't cancel a helper; only the agent can." if invocation.helper
    found = Tool::CheckHelper.find(conversation, helper)
    raise Refusal, "That helper has already ended, so there is nothing to cancel." unless found.cancel(by_agent: true)
    { cancelled: true, calls: found.call_count }
  end
end
