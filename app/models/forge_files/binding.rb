class ForgeFiles::Binding
  def self.check!(invocation)
    invocation.reload
    agent = invocation.agent
    workspace = agent.workspace
    settings = DurableAssistants.config(:pi_durable, :forge_files, default: {})
    raise Agent::Access::Forbidden unless agent.persisted? && workspace &&
      settings[:agent_id].to_s == agent.id.to_s && settings[:workspace_id].to_s == workspace.id.to_s &&
      !agent.paused? && Admission.admits?(agent.user.email) && workspace.member?(agent.user)
    raise Agent::Access::Forbidden unless invocation.call_name == "forge" && Invocation.agents_own?(invocation.call_id) &&
      !invocation.helper && invocation.running? && invocation.started_at&.after?(Invocation::RUN_LIMIT.ago)
  end
end
