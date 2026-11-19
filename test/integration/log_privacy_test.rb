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

  # A phone's device token is kept in Push::Device and nowhere else: not the log, not what became of Turn on.
  test "a device token is never logged, nor kept with Turn on's outcome" do
    token = "a1b2" * 16
    log = StringIO.new
    Rails.logger.broadcast_to(listener = ActiveSupport::Logger.new(log))
    post "/push/devices", params: { token: token.upcase }, headers: { "User-Agent" => "Lanyard/0.1(12) APNs/sandbox" }, as: :json
    post "/push/attempts", params: { outcome: "rejected", code: 422, token: token }, as: :json
    Rails.logger.stop_broadcasting_to(listener)

    assert_match "Push attempt: registered", log.string
    assert_match "Push attempt: rejected (422)", log.string
    assert_no_match(/#{token}/i, log.string)
    assert_equal [ token ], Push::Device.pluck(:token) # tenancy-ok: test checks where the token went
    assert_equal 2, Push::Attempt.count # tenancy-ok: test checks where the token went
    assert_no_match(/#{token}/i, Push::Attempt.all.map(&:attributes).inspect) # tenancy-ok: test checks where the token went
  end

  # A connector's callback carries the service's one-time code and the sign-in's state.
  test "the request log filters a connector callback's code and state with or without a session" do
    code, state = "synthetic-callback-code", "synthetic-callback-state"
    path = connectors_callback_path(code: code, state: state)
    [ self, open_session ].each do |client|
      log = StringIO.new
      Rails.logger.broadcast_to(listener = ActiveSupport::Logger.new(log))
      client.get path

      assert_match 'Started GET "/connectors/callback?', log.string
      assert_match '"code" => "[FILTERED]"', log.string
      assert_match '"state" => "[FILTERED]"', log.string
      assert_no_match Regexp.union(code, state), log.string
    ensure
      Rails.logger.stop_broadcasting_to(listener)
    end
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
