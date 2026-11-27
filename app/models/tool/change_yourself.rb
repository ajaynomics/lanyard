# How an agent changes its own instructions when the person asks. Its name is
# fixed when it is made, and every version is kept (Agent::Revision).
#
# With scope "workspace" it proposes instead a change to its workspace's
# shared instructions, which every agent there follows: an argument, not a
# tool of its own, so no agent's tool count rises. That reaches beyond the
# agent, so only the workspace's owner may allow it, every time, whatever the
# own-instruction setting says (Workspace::SharedInstructions).
class Tool::ChangeYourself < Tool
  LIMIT = 32_768
  MAX_EDITS = 32
  Change = Data.define(:offset, :from, :to)

  description "Change your instructions when the person asks. Prefer edits: give the exact saved text to find and its " \
    "replacement (empty to delete). Each find must occur once, and all edits refer to the same saved instructions. " \
    "For a rewrite, give the complete new instructions instead. Leave out the lines about your name, email address, " \
    "title and phone number, and your workspace's shared instructions; the app adds them. " \
    "Your own changes ask for approval by default and apply from the next message. " \
    "Use scope \"workspace\" for the workspace's shared instructions; its owner must always allow that."
  argument :instructions, :string, required: false, min_length: 1, max_length: LIMIT,
    description: "The complete new instructions in Markdown. Use only for a rewrite, not with edits."
  argument :edits, :array, required: false, min_items: 1, max_items: MAX_EDITS,
    items: { type: "object", additionalProperties: false, required: %w[ find replace ], properties: {
      find: { type: "string", minLength: 1, maxLength: LIMIT },
      replace: { type: "string", maxLength: LIMIT }
    } }, description: "Literal, non-overlapping replacements against the same saved text. Not with instructions."
  argument :scope, :string, required: false, enum: %w[ yourself workspace ],
    description: "\"yourself\" (the default) for your instructions, \"workspace\" for the workspace's shared ones."
  # "Always" would let mail or a page the agent read rewrite it unseen.
  asks :approval, always: false
  changes_itself

  # Providers won't accept oneOf at the top of a tool schema.
  def self.errors_for(values)
    problems = super
    return problems if problems.any?
    values.key?("edits") ^ values.key?("instructions") ? [] : [ "Give either edits or instructions, not both or neither." ]
  end

  def asks = (super if every_time? || invocation.awaiting_person?)

  def every_time? = workspace? || agent.asks_own_instruction_change?
  def even_approving_everything? = every_time?

  def approver = (agent.workspace.owner if workspace?)

  def approval_title(_arguments)
    "Change #{agent.workspace}'s shared instructions?" if workspace?
  end

  def approval_note(_arguments)
    if workspace?
      "Every agent in #{agent.workspace} follows these. Only #{approver}, its owner, can allow it."
    else
      "Changing #{agent}'s own instructions requires approval."
    end
  end

  # Bind the card to the saved text and revision it was proposed against
  # (Proposal). The invocation saves this snapshot when it is received.
  def refusal
    invocation.preview = { Proposal::KEY => Proposal.new(invocation).snapshot }
    nil
  rescue Refusal => problem
    problem.message
  end

  def call(**)
    # An unanswered card or an old claim must not run as an unasked change.
    approval = invocation.approval
    approved = invocation.approved? && approval&.decision == "approve"
    unasked = invocation.pending? && approval.nil? && !every_time?
    raise Refusal, Proposal::STALE unless approved || unasked

    warning = Proposal.new(invocation).apply!(approval: approval)
    { instructions: "saved", warning: warning }.compact
  end

  private
    def workspace? = arguments["scope"] == "workspace"
end
