# How an agent changes its own instructions when the person asks, as a hosted assistant
# does. Its name is fixed when it is made. The person approves the exact change, so mail or a page the agent
# read cannot rewrite it unseen; every version is kept (Agent::Revision).
class Tool::ChangeYourself < Tool
  description "Change your own instructions when the person asks you to: your tone, your job, what to " \
    "remember to do or avoid. Send the whole new instructions, not just the change. The person approves it first, " \
    "and it applies from the next message. Your name and email address can't be changed."
  argument :instructions, :string, required: true, min_length: 1, max_length: 32_768,
    description: "Your complete new instructions, in Markdown. Start from your current ones."
  # "Always" would let mail or a page the agent read rewrite it unseen.
  asks :approval, always: false

  def call(instructions:)
    raise Refusal, agent.errors.full_messages.to_sentence unless agent.update(instructions: instructions)
    { instructions: "saved" }
  end
end
