# People, bots and sidecar settings for tests. There are no fixtures: records
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

  def create_user(name: "Alice", email: "#{name.downcase}@example.com")
    User.sign_in_from_oidc!(sub: "sub-#{name.downcase}", email: email, name: name)
  end

  def create_conversation(bot, durable_id: "12", request_id: "r-#{durable_id}")
    bot.conversations.create!(user: bot.user, request_id: request_id, durable_id: durable_id)
  end

  # The client needs only the two ids it puts on the wire.
  def synthetic_access = Struct.new(:actor_id, :workspace_id).new("alice", "one")

  def rails_bearer(token = RAILS_TOKEN)
    { "Authorization" => "Bearer #{token}" }
  end

  def invocation_payload(conversation, tool:, arguments:, task_id: 7, call_id: "toolu_1")
    digest = Invocation.digest_for(conversation, task_id: task_id, call_id: call_id, tool: tool, arguments: arguments)
    { actorId: conversation.user_id.to_s, workspaceId: conversation.bot_id.to_s, conversationId: conversation.durable_id,
      taskId: task_id, callId: call_id, tool: tool, arguments: arguments, digest: digest }
  end
end
