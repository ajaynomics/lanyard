# Synthetic adapters and settings for the agent tests. The generated app
# ships with no identity or authorization adapter, so it refuses everything;
# these stand in for the application's own, for one test at a time.
module AgentTestHelper
  SIDECAR = "http://127.0.0.1:9".freeze # the discard port: an unstubbed call fails
  SIDECAR_TOKEN = "synthetic-sidecar-token-0123".freeze
  RAILS_TOKEN = "synthetic-rails-token-456789".freeze
  Principal = Struct.new(:id)
  SETTINGS = %i[pi_durable pi_durable_identity pi_durable_authorize].freeze

  def install_agent_adapters(actor: "alice", workspaces: %w[one], sidecar_token: SIDECAR_TOKEN, rails_token: RAILS_TOKEN)
    x = Rails.application.config.x
    @saved_agent_settings ||= SETTINGS.index_with { |name| x.public_send(name) }
    x.pi_durable = { sidecar_url: SIDECAR, sidecar_token: sidecar_token, rails_token: rails_token }
    x.pi_durable_identity = ->(_controller) { Principal.new(actor) if actor }
    x.pi_durable_authorize = lambda do |actor_id, workspace_id|
      next unless actor_id == actor && workspaces.include?(workspace_id)
      Agent::Access.new(actor_id: actor_id, workspace_id: workspace_id, cwd: Rails.root.join("tmp/agent", workspace_id).to_s)
    end
  end

  def remove_agent_adapters
    @saved_agent_settings&.each { |name, value| Rails.application.config.x.public_send("#{name}=", value) }
    @saved_agent_settings = nil
  end

  def alice_in(workspace = "one")
    Agent::Access.new(actor_id: "alice", workspace_id: workspace, cwd: Rails.root.join("tmp/agent", workspace).to_s)
  end

  def rails_bearer(token = RAILS_TOKEN)
    { "Authorization" => "Bearer #{token}" }
  end

  def effect_payload(access, task_id: 7, call_id: "tool:1:abc", arguments: { "key" => "greeting", "body" => "hello" })
    digest = Agent::Effect.digest_for(access, task_id: task_id, call_id: call_id, arguments: arguments)
    { actorId: access.actor_id, workspaceId: access.workspace_id, taskId: task_id, callId: call_id,
      tool: "rails_note", arguments: arguments, digest: digest }
  end
end
