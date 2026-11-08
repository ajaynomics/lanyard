require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# What people write, what the agent says and the secrets in a pasted connector
# reach the database or the sidecar, never the log.
class LogPrivacyTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  SECRET = "WORD-THAT-MUST-NOT-BE-LOGGED".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "frames, an agent's instructions and purpose, a skill and a pasted connector file are filtered" do
    stub_request(:any, %r{\Ahttps://wiki\.acme\.example/}).to_return(status: 503)
    log = logged do
      post "/agent/frames", headers: rails_bearer, as: :json, params: {
        actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s, conversationId: @conversation.durable_id, seq: 1, busy: true,
        tail: SECRET, thinking: SECRET, tools: [ { callId: "c1", name: "bash", status: "running", output: SECRET } ] }
      patch agent_path(@agent), params: { agent: { instructions: SECRET } }
      post agents_path, params: { agent: { name: "Trips", purpose: SECRET } }
      post agent_skills_path(@agent), params: { skill: { markdown: SECRET } }
      post connectors_path, params: { connector: { json: { mcpServers: { wiki: { url: "https://wiki.acme.example/mcp",
        headers: { "X-Api" => SECRET } } } }.to_json } }
    end

    assert_equal 5, log.scan("Parameters").size
    assert_no_match SECRET, log
  end

  private
    def logged
      log = StringIO.new
      logger, ActionController::Base.logger = ActionController::Base.logger, ActiveSupport::Logger.new(log)
      yield
      log.string
    ensure
      ActionController::Base.logger = logger
    end
end
