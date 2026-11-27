class Tool::BriefReport < Tool
  description "Queue the first message for an approved direct report in this workspace, as yourself. The owner sees and approves the exact message. " \
    "Quote a source as a relay, not as the sender. This is not a Concourse send and does not give the report a network identity."
  argument :report_id, :integer, minimum: 1, description: "The exact local report ID from your reporting lines."
  argument :message, :string, min_length: 1, max_length: 4_000
  asks :approval, even_approving_everything: true
  effect :external
  safe_to_repeat

  def approver = agent.workspace.owner

  def refusal
    "Only the current manager of an approved report can brief it." unless setup_for(arguments["report_id"])
  end

  def approval_title(arguments)
    report = setup_for(arguments["report_id"])&.scoped_agent
    "Approve #{agent.name}’s first message to #{report&.name || 'its report'}?"
  end

  def details(arguments) = { "Message" => arguments["message"] }

  def call(report_id:, message:)
    setup = setup_for(report_id) or raise Refusal, "Only the current manager of an approved report can brief it."
    turn = setup.prepare_first_turn!(message, by: agent)
    turn.deliver(wait_for_computer: true)
    { report_id: report_id, request_id: turn.request_id, accepted: turn.reload.accepted_at.present? }
  rescue ActiveRecord::RecordNotFound, Workspace::AgentSetup::Conflict, Conversation::Submission::Refused => error
    raise Refusal, error.is_a?(ActiveRecord::RecordNotFound) ? "The report's setup is no longer authorized." : error.message
  end

  private
    def setup_for(report_id)
      agent.workspace.agent_setups.where(manager_id: agent.id, revoked_at: nil, undone_at: nil).where.not(executed_at: nil).find_by(agent_id: report_id)
    end
end
