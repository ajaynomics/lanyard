require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The sidecar's callbacks into Rails: bearer-token transport with RAILS_TOKEN,
# never the sidecar's own token, no CSRF, and deny by default.
class Agent::PrivateCallbacksTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup { install_agent_adapters }
  teardown { remove_agent_adapters }

  test "an access names exactly the scope asked about" do
    post "/agent/accesses", params: { actorId: "alice", workspaceId: "one" }, headers: rails_bearer, as: :json

    assert_response :ok
    assert_equal({ "allowed" => true, "actorId" => "alice", "workspaceId" => "one", "cwd" => alice_in.cwd }, response.parsed_body)
  end

  test "access is denied by default" do
    post "/agent/accesses", params: { actorId: "mallory", workspaceId: "one" }, headers: rails_bearer, as: :json
    assert_response :forbidden

    post "/agent/accesses", params: { actorId: "alice", workspaceId: "two" }, headers: rails_bearer, as: :json
    assert_response :forbidden

    Rails.application.config.x.pi_durable_authorize = nil
    post "/agent/accesses", params: { actorId: "alice", workspaceId: "one" }, headers: rails_bearer, as: :json
    assert_response :forbidden
  end

  test "an adapter that answers for a different scope is refused" do
    Rails.application.config.x.pi_durable_authorize = ->(_actor, _workspace) { alice_in("two") }
    post "/agent/accesses", params: { actorId: "alice", workspaceId: "one" }, headers: rails_bearer, as: :json

    assert_response :forbidden
  end

  test "only RAILS_TOKEN authenticates the transport" do
    [ {}, rails_bearer("wrong-token-0123456789"), rails_bearer(SIDECAR_TOKEN) ].each do |headers|
      post "/agent/accesses", params: { actorId: "alice", workspaceId: "one" }, headers: headers, as: :json
      assert_response :unauthorized
    end
  end

  test "blank or shared tokens refuse every callback" do
    install_agent_adapters(rails_token: nil)
    post "/agent/accesses", params: { actorId: "alice", workspaceId: "one" }, headers: { "Authorization" => "Bearer " }, as: :json
    assert_response :unauthorized

    install_agent_adapters(rails_token: SIDECAR_TOKEN)
    post "/agent/accesses", params: { actorId: "alice", workspaceId: "one" }, headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
  end

  test "callbacks skip CSRF because the transport is authenticated instead" do
    with_forgery_protection do
      post "/agent/effects", params: effect_payload(alice_in), headers: rails_bearer, as: :json
    end

    assert_response :ok
    assert_equal "hello", response.parsed_body["body"]
  end

  test "an effect is idempotent and a conflicting reuse is refused" do
    2.times { post "/agent/effects", params: effect_payload(alice_in), headers: rails_bearer, as: :json }
    assert_response :ok
    assert_equal 1, alice_in.effects.count

    changed = effect_payload(alice_in, arguments: { "key" => "greeting", "body" => "changed" })
    post "/agent/effects", params: changed, headers: rails_bearer, as: :json
    assert_response :conflict
    assert_equal "hello", alice_in.notes.sole.body
  end

  test "an effect for an unauthorised scope writes nothing" do
    post "/agent/effects", params: effect_payload(alice_in("two")), headers: rails_bearer, as: :json

    assert_response :forbidden
    assert_equal 0, Agent::Effect.count # tenancy-ok: proving nothing was written anywhere
  end

  private
    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
