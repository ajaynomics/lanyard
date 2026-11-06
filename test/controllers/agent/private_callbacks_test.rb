require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The sidecar's callbacks into Rails: bearer-token transport with RAILS_TOKEN,
# never the sidecar's own token, no CSRF, and deny by default.
class Agent::PrivateCallbacksTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @bot = @alice.bots.sole
    @conversation = create_conversation(@bot)
  end
  teardown { remove_sidecar_settings }

  test "an access names exactly the user and bot asked about" do
    post "/agent/accesses", params: scope, headers: rails_bearer, as: :json

    assert_response :ok
    assert_equal({ "allowed" => true, "actorId" => @alice.id.to_s, "workspaceId" => @bot.id.to_s, "cwd" => @bot.workdir }, response.parsed_body)
  end

  test "another person's bot is refused" do
    mallory = create_user(name: "Mallory")

    post "/agent/accesses", params: { actorId: mallory.id.to_s, workspaceId: @bot.id.to_s }, headers: rails_bearer, as: :json
    assert_response :forbidden

    post "/agent/accesses", params: { actorId: @alice.id.to_s, workspaceId: "999999" }, headers: rails_bearer, as: :json
    assert_response :forbidden
  end

  test "only RAILS_TOKEN authenticates the transport" do
    [ {}, rails_bearer("wrong-token-0123456789"), rails_bearer(SIDECAR_TOKEN) ].each do |headers|
      post "/agent/accesses", params: scope, headers: headers, as: :json
      assert_response :unauthorized
    end
  end

  test "blank or shared tokens refuse every callback" do
    install_sidecar_settings(rails_token: nil)
    post "/agent/accesses", params: scope, headers: { "Authorization" => "Bearer " }, as: :json
    assert_response :unauthorized

    install_sidecar_settings(rails_token: SIDECAR_TOKEN)
    post "/agent/accesses", params: scope, headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
  end

  test "a tool call runs once, skipping CSRF because the transport is authenticated instead" do
    payload = invocation_payload(@conversation, tool: "remember_note", arguments: { "key" => "dentist", "body" => "Tuesday 3pm" })

    with_forgery_protection do
      2.times { post "/agent/invocations", params: payload, headers: rails_bearer, as: :json }
    end

    assert_response :ok
    assert_equal({ "status" => "done", "result" => { "key" => "dentist", "body" => "Tuesday 3pm" }, "isError" => false }, response.parsed_body)
    assert_equal 1, @conversation.invocations.count
    assert_equal "Tuesday 3pm", @bot.notes.sole.body
  end

  test "a changed call under the same identity is a conflict and changes nothing" do
    post "/agent/invocations", params: invocation_payload(@conversation, tool: "remember_note", arguments: { "key" => "k", "body" => "first" }),
      headers: rails_bearer, as: :json
    post "/agent/invocations", params: invocation_payload(@conversation, tool: "remember_note", arguments: { "key" => "k", "body" => "second" }),
      headers: rails_bearer, as: :json

    assert_response :conflict
    assert_equal "first", @bot.notes.sole.body
  end

  test "a forged digest is a conflict" do
    payload = invocation_payload(@conversation, tool: "current_time", arguments: {}).merge(digest: "0" * 64)
    post "/agent/invocations", params: payload, headers: rails_bearer, as: :json

    assert_response :conflict
    assert_empty @conversation.invocations
  end

  test "a call naming another person's conversation reaches nothing" do
    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.bots.sole, durable_id: "99")
    payload = invocation_payload(theirs, tool: "current_time", arguments: {}).merge(actorId: @alice.id.to_s, workspaceId: @bot.id.to_s)

    post "/agent/invocations", params: payload, headers: rails_bearer, as: :json

    assert_response :not_found
    assert_empty theirs.invocations
  end

  private
    def scope = { actorId: @alice.id.to_s, workspaceId: @bot.id.to_s }

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
