require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::PausesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  test "the person pauses an agent from its settings, sees it paused there, in the list and on its thread, holds and drops a message, and resumes it" do
    post agent_pause_path(@agent)
    assert_redirected_to agent_path(@agent)
    assert @agent.reload.paused?

    get agent_path(@agent)
    assert_select "#agent_pause button", text: "Resume"
    get root_path
    assert_select ".conversation-row__badge", text: "Paused"

    @agent.conversation.receive("Hello", from: "sam@example.com", via: "Email", request_id: "email:1")
    held = @agent.conversation.held.sole
    get conversation_path(@agent.conversation)
    assert_select ".message--held", text: /sam@example\.com/
    assert_select ".chat-sidebar .conversation-row__text .conversation-row__badge", text: "Paused"
    assert_select "template[data-echo-target=working]", count: 0, message: "a send while paused is held: no typing dots"
    delete conversation_held_message_path(@agent.conversation, held)
    assert_empty @agent.conversation.held

    delete agent_pause_path(@agent)
    assert_redirected_to agent_path(@agent)
    assert_not @agent.reload.paused?
    perform_enqueued_jobs
    get agent_path(@agent)
    assert_select "#agent_pause button", text: "Pause"
  end

  test "while it resumes there is neither Pause nor Drop, and a Drop sent anyway is refused" do
    stub_request(:any, /#{SIDECAR}/).to_return(status: 503, body: { error: "unavailable" }.to_json)
    @agent.pause
    @agent.conversation.receive("Hello", from: "sam@example.com", via: "Email", request_id: "email:1")
    held = @agent.conversation.held.sole
    @agent.resume

    get agent_path(@agent)
    assert_select "#agent_pause button", count: 0
    get conversation_path(@agent.conversation)
    assert_select ".message--held button", text: "Drop", count: 0
    delete conversation_held_message_path(@agent.conversation, held), as: :turbo_stream
    assert_match "Too late to drop", response.body
    assert_equal [ held ], @agent.conversation.held.to_a
  end

  test "another person's agent is not found" do
    other = create_user(name: "Mallory").agents.sole
    post agent_pause_path(other)
    assert_response :not_found
    assert_not other.reload.paused?
  end
end
