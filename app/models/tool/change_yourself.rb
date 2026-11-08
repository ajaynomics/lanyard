# How an agent changes its own name or instructions when the person asks, as
# a hosted assistant does. The person approves the exact change, so mail or a page the agent
# read cannot rewrite it unseen; every version is kept (Agent::Revision).
class Tool::ChangeYourself < Tool
  description "Change your own name or instructions when the person asks you to: your tone, your job, what to " \
    "remember to do or avoid. Send the whole new instructions, not just the change. The person approves it first, " \
    "and it applies from the next message."
  argument :name, :string, required: false, min_length: 1, max_length: 200, description: "Your new name."
  argument :instructions, :string, required: false, min_length: 1, max_length: 32_768,
    description: "Your complete new instructions, in Markdown. Start from your current ones."
  # "Always" would let mail or a page the agent read rewrite it unseen.
  asks :approval, always: false

  def call(name: nil, instructions: nil)
    raise Refusal, "Send a new name, new instructions, or both." unless name || instructions
    raise Refusal, agent.errors.full_messages.to_sentence unless agent.update({ name: name, instructions: instructions }.compact)
    { name: agent.name, instructions: "saved" }
  end
end
