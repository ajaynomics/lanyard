# How an agent changes its own instructions when the person asks. Its name is fixed when it is made. The person approves the exact change, so mail or a page the agent
# read cannot rewrite it unseen; every version is kept (Agent::Revision).
#
# With scope "workspace" it proposes instead a change to its workspace's
# shared instructions, which every agent there follows: an argument, not a
# tool of its own, so no agent's tool count rises. That reaches beyond the
# agent, so only the workspace's owner may allow it, every time, whatever the
# install or the agent's switch says (Workspace::SharedInstructions).
class Tool::ChangeYourself < Tool
  description "Change your own instructions when the person asks you to: your tone, your job, what to " \
    "remember to do or avoid. Send the whole new instructions, not just the change. The person approves it first, " \
    "and it applies from the next message. Your name and email address can't be changed. Leave out the lines " \
    "about your name, email address, title and phone number, and your workspace's shared instructions; the app adds them. " \
    "With scope \"workspace\", propose instead new shared instructions for your workspace, which every agent in it " \
    "follows; only the workspace's owner can allow that."
  argument :instructions, :string, required: true, min_length: 1, max_length: 32_768,
    description: "Your complete new instructions, in Markdown, or with scope \"workspace\" the workspace's complete " \
      "shared instructions. Start from the current ones."
  argument :scope, :string, required: false, enum: %w[ yourself workspace ],
    description: "\"yourself\" (the default) for your own instructions, \"workspace\" for your workspace's shared ones."
  # "Always" would let mail or a page the agent read rewrite it unseen.
  asks :approval, always: false
  changes_itself

  # A person's per-agent choice on the Permissions page, stronger than the
  # install's approval policy. Off leaves the rules above alone. Not an
  # argument, so the agent can't turn it off.
  SETTINGS = { "change_yourself" => [ :asks_every_instruction_change, "Ask before every change to its instructions" ] }.freeze

  def every_time? = workspace? || agent.asks_every_instruction_change? || super
  def even_approving_everything? = workspace? || agent.asks_every_instruction_change? || super

  def approver = (agent.workspace.owner if workspace?)

  def approval_title(_arguments)
    "Change #{agent.workspace}'s shared instructions?" if workspace?
  end

  def approval_note(_arguments)
    if workspace?
      "Every agent in #{agent.workspace} follows these. Only #{approver}, its owner, can allow it."
    elsif agent.asks_every_instruction_change?
      "#{agent} is set to #{SETTINGS.fetch(self.class.tool_name).last.downcase_first}, so this asks every time."
    end
  end

  def details(arguments)
    InstructionsChange.new(workspace? ? agent.workspace.instructions : agent.instructions, arguments["instructions"]).details
  end

  def call(instructions:, scope: "yourself")
    if workspace?
      by = invocation.approval&.decided_by
      raise Refusal, "Only #{approver}, the workspace's owner, can allow this." unless by && by == approver
      agent.workspace.change_instructions(instructions, by: by, proposed_by: agent)
    else
      raise Refusal, agent.errors.full_messages.to_sentence unless agent.update(instructions: instructions)
    end
    { instructions: "saved" }
  rescue ActiveRecord::RecordInvalid => invalid
    raise Refusal, invalid.record.errors.full_messages.to_sentence
  end

  private
    def workspace? = arguments["scope"] == "workspace"
end
