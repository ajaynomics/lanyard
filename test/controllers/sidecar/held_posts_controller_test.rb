require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Sidecar::HeldPostsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @person = create_user
    @conversation = create_conversation(@person.agents.sole)
    @scope = invocation_payload(@conversation, tool: "current_time", arguments: {}).slice(:actorId, :workspaceId, :conversationId)
    @post = { id: "1" * 48, site: "https://example.com", method: "POST", path: "/order",
      targetDigest: "2" * 64, digest: "3" * 64, expiresAt: (60.seconds.from_now.to_f * 1000).to_i,
      fields: [ [ "note", "synthetic order" ], [ "password", "[withheld]" ] ] }
  end

  teardown { remove_sidecar_settings }

  test "only one card is opened and it allows once, even when tools are allowed without asking" do
    2.times { callback("open") }
    assert_response :ok
    assert_equal "waiting", response.parsed_body.fetch("status")
    card = @conversation.invocations.sole
    assert_equal :outside_send, card.approval_kind
    assert_equal "https://example.com", card.details["site"]
    assert_includes card.details["fields"], "password: [withheld]"
    assert_empty card.always_choices
    assert_raises(ArgumentError) { card.approve!(by: @person, always: "agent") }
    card.approve!(by: @person)
    assert_equal "outside_send", card.approval.kind
    callback("answer")
    assert_equal "allow", response.parsed_body.fetch("status")
    callback("answer")
    assert_equal "deny", response.parsed_body.fetch("status")
  end

  test "an altered answer, a deny and an expired approval never release a request" do
    callback("open")
    card = @conversation.invocations.sole
    callback("answer", @post.merge(targetDigest: "4" * 64))
    assert_response :conflict
    card.deny!(by: @person)
    callback("answer")
    assert_equal "deny", response.parsed_body.fetch("status")

    later = @post.merge(id: "5" * 48)
    callback("open", later)
    card = @conversation.invocations.find_by!(call_id: later[:id])
    card.approve!(by: @person)
    travel 61.seconds do
      callback("answer", later)
      assert_equal "deny", response.parsed_body.fetch("status")
    end
  end

  test "the transport neither admits strangers nor saves an unredacted password" do
    callback("open", headers: {})
    assert_response :unauthorized
    callback("open", headers: rails_bearer.merge("Cf-Ray" => "sample"))
    assert_response :not_found
    callback("open", @post.merge(fields: [ [ "password", "never write this" ] ]))
    assert_response :conflict
    assert_empty @conversation.invocations
  end

  test "disconnect closes the card and a normal tool invocation cannot create it" do
    callback("open")
    callback("cancel")
    assert_equal "deny", response.parsed_body.fetch("status")
    assert @conversation.invocations.sole.failed?

    post "/agent/invocations", params: invocation_payload(@conversation, tool: "outside_send", arguments: {},
      task_id: "browser-hold", call_id: @post[:id]), headers: rails_bearer, as: :json
    assert_response :conflict
  end

  private
    def callback(operation, held_post = @post, headers: rails_bearer)
      post "/agent/held_posts", params: @scope.merge(operation: operation, held_post: held_post), headers: headers, as: :json
    end
end
