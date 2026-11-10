# People, agents and sidecar settings for tests. There are no fixtures: records
# are built through the models, and the sidecar is stubbed at Rails' HTTP
# client (an unstubbed call lands on the discard port and fails).
module AgentTestHelper
  SIDECAR = "http://127.0.0.1:9".freeze
  SIDECAR_TOKEN = "synthetic-sidecar-token-0123".freeze
  RAILS_TOKEN = "synthetic-rails-token-456789".freeze

  def install_sidecar_settings(sidecar_token: SIDECAR_TOKEN, rails_token: RAILS_TOKEN)
    x = Rails.application.config.x
    @saved_pi_durable ||= x.pi_durable
    x.pi_durable = x.pi_durable.to_h.merge(sidecar_url: SIDECAR, sidecar_token: sidecar_token, rails_token: rails_token)
  end

  def remove_sidecar_settings
    Rails.application.config.x.pi_durable = @saved_pi_durable if @saved_pi_durable
    @saved_pi_durable = nil
  end

  # A person with an agent of their own: the starter for the first, and for a
  # later one, who would start with none (User#start_starter), one named for them.
  def create_user(name: "Alice", email: "#{name.downcase}@example.com")
    User.sign_in!(sub: "sub-#{name.downcase}", email: email, name: name).tap do
      it.start_agent("#{name}'s assistant") if it.agents.none?
    end
  end

  # The agent's thread, admitted as the sidecar conversation `durable_id`. An
  # agent is one thread, so once its own is taken a further one is another
  # agent made like it.
  def create_conversation(agent, durable_id: "12", request_id: "r-#{durable_id}")
    agent = agent.user.agents.create!(agent.attributes.slice(*%w[ name instructions model thinking_level time_zone tool_names capabilities ])) if agent.conversation.durable_id
    agent.conversation.tap { it.update!(durable_id: durable_id, request_id: request_id) }
  end

  # An agent's name is fixed when it is made; a test that wants an existing
  # agent under another name writes it as if it had been given then.
  def name_agent(agent, name)
    Agent.where(id: agent.id).update_all(name: name)
    agent.reload
  end

  # The client needs only the two ids it puts on the wire.
  def synthetic_access = Struct.new(:actor_id, :workspace_id).new("alice", "one")

  # What was sent, without the date a thread is told once a day (Conversation#date_note).
  def words(content) = content.to_s.sub(Conversation::DATE_NOTE, "")

  def rails_bearer(token = RAILS_TOKEN)
    { "Authorization" => "Bearer #{token}" }
  end

  def invocation_payload(conversation, tool:, arguments:, task_id: 7, call_id: "toolu_1")
    digest = Invocation.digest_for(conversation, task_id: task_id, call_id: call_id, tool: tool, arguments: arguments)
    { actorId: conversation.user_id.to_s, workspaceId: conversation.agent_id.to_s, conversationId: conversation.durable_id,
      taskId: task_id, callId: call_id, tool: tool, arguments: arguments, digest: digest }
  end
end
