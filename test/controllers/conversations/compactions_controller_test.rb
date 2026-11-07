require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversations::CompactionsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    @scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s }
  end
  teardown { remove_sidecar_settings }

  test "/compact asks the sidecar for a summary, with the person's words, and goes back to the conversation" do
    compact = stub_request(:post, "#{SIDECAR}/v1/conversations/12/compactions")
      .with(body: @scope.merge(requestId: "c-1", instructions: "Keep the dates")).to_return(status: 202, body: { id: "31" }.to_json)

    post conversation_compactions_path(@conversation), params: { request_id: "c-1", instructions: "  Keep the dates  " }

    assert_requested compact
    assert_redirected_to conversation_path(@conversation)
    assert_response :see_other
  end

  test "a bad request id or too many words is refused before the sidecar is asked" do
    post conversation_compactions_path(@conversation), params: { request_id: "bad id!" }
    assert_response :bad_request

    post conversation_compactions_path(@conversation), params: { request_id: "c-2", instructions: "x" * 4_097 }
    assert_response :bad_request
    assert_not_requested :post, "#{SIDECAR}/v1/conversations/12/compactions"
  end

  test "another person's conversation is not found" do
    theirs = create_conversation(create_user(name: "Mallory").agents.sole, durable_id: "99")

    post conversation_compactions_path(theirs), params: { request_id: "c-3" }

    assert_response :not_found
  end

  test "an unreachable sidecar is a 503 to the page that asked, and a plain message to a person" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/compactions").to_return(status: 503, body: { error: "not_ready" }.to_json)

    post conversation_compactions_path(@conversation), params: { request_id: "c-4" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :service_unavailable

    post conversation_compactions_path(@conversation), params: { request_id: "c-4" }
    assert_redirected_to root_path
    assert_equal "The assistant is not reachable right now. Try again shortly.", flash[:alert]
  end
end
