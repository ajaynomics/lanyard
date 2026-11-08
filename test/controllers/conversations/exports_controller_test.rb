require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversations::ExportsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    name_agent(@agent, "Plan a trip ✓")
    @scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s }
  end
  teardown { remove_sidecar_settings }

  test "the history downloads as pi's session file, named after the agent, as the sidecar writes it" do
    file = "#{{ type: 'session', version: 3, id: 's', timestamp: '2026-11-06T00:00:00.000Z', cwd: '.' }.to_json}\n" \
      "#{{ type: 'session_info', id: 's0000001', parentId: nil, timestamp: '2026-11-06T00:00:00.000Z', name: 'Plan a trip ✓' }.to_json}\n"
    export = stub_request(:get, "#{SIDECAR}/v1/conversations/12/export").with(query: @scope.merge(title: "Plan a trip ✓"))
      .to_return(body: file, headers: { "Content-Type" => "application/jsonl" })

    get conversation_export_path(@conversation, format: :jsonl)

    assert_requested export
    assert_response :ok
    assert_equal "application/jsonl", response.media_type
    assert_includes response.headers["Content-Disposition"], "attachment; filename=\"Plan a trip %3F.jsonl\"; filename*=UTF-8''Plan%20a%20trip%20%E2%9C%93.jsonl"
    assert_equal file, response.body
    assert_equal 3, JSON.parse(response.body.lines.first)["version"]
  end

  test "another person's conversation is not found, and only the session file is offered" do
    theirs = create_conversation(create_user(name: "Mallory").agents.sole, durable_id: "99")
    get conversation_export_path(theirs, format: :jsonl)
    assert_response :not_found

    get conversation_export_path(@conversation, format: :html)
    assert_response :not_acceptable
    assert_not_requested :get, "#{SIDECAR}/v1/conversations/12/export", query: hash_including({})
  end

  test "a sidecar that cannot answer is a 503, not an empty download" do
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/export").with(query: hash_including({})).to_return(status: 503, body: { error: "not_ready" }.to_json)

    get conversation_export_path(@conversation, format: :jsonl)

    assert_response :service_unavailable
    assert_nil response.headers["Content-Disposition"]
  end
end
