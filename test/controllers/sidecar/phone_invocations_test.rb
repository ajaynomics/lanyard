require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Sidecar::PhoneInvocationsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @agent.workspace.update!(approval_policy: "everything")
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "a phone request cannot reach a send or change state, even approving everything" do
    assert_no_difference [ "Invocation.count", "Approval.count", "Dispatch.count" ] do
      post_call phone_call("send_text", { "to" => "4165550199", "body" => "Hello" })
      assert_response :conflict
      post_call phone_call("remember_note", { "key" => "phone", "body" => "Do not save this" })
      assert_response :conflict
    end
    assert_empty @agent.notes
  end

  test "a phone read runs and the same call cannot replay without its phone scope" do
    call = phone_call("current_time", {})
    post_call call
    assert_response :success
    assert response.parsed_body.fetch("result").fetch("now").present?

    post_call call.except(:phone)
    assert_response :conflict
    post_call invocation_payload(@conversation, tool: "current_time", arguments: {})
    assert_response :conflict
    assert_equal 1, @conversation.invocations.count
  end

  private
    def phone_call(tool, arguments)
      data = invocation_payload(@conversation, tool:, arguments:).except(:digest).merge(phone: true)
      data.merge(digest: Agent::Canonical.digest(data))
    end

    def post_call(data)
      post "/agent/invocations", params: data, headers: rails_bearer, as: :json
    end
end
