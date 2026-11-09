require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

class Agents::PeerTasksControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper, ConcourseTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "the agent's open tasks, both ways, in words, each with the thread or branch it lives in; settled ones are gone" do
    create_concourse_agent(@agent)
    branch = @agent.conversations.create!(user: @agent.user, request_id: "b-1", parent: @conversation, root: @conversation, title: "Lee's notes", durable_id: "13")
    branch.peer_tasks.create!(task_id: "a1b2c3d4-0000", peer: "acme/lee", direction: "outbound", state: "TASK_STATE_INPUT_REQUIRED")
    @conversation.peer_tasks.create!(task_id: "e5f6a7b8-0000", peer: "acme/robin", direction: "inbound", state: "TASK_STATE_WORKING")
    @conversation.peer_tasks.create!(task_id: "done-0000", peer: "acme/sam", direction: "outbound", state: "TASK_STATE_COMPLETED")

    get agent_peer_tasks_path(@agent)

    assert_select "a[aria-current=page]", text: "Concourse tasks"
    assert_select "#outbound_tasks", text: "Waiting on others"
    assert_select "#outbound_tasks + .ui-group__rows .ui-row", count: 1, text: /To acme\/lee.*Asks a question · sent less than a minute ago.*Task a1b2c3d4/m do
      assert_select "a[href=?]", conversation_path(branch), text: "Open branch"
    end
    assert_select "#inbound_tasks + .ui-group__rows .ui-row", count: 1, text: /From acme\/robin.*Working/m do
      assert_select "a[href=?]", conversation_path(@conversation), text: "Open thread"
    end
    assert_select ".ui-row", text: /acme\/sam/, count: 0
  end

  test "none open says what will show; an agent off Concourse has no section for it" do
    get agent_path(@agent)
    assert_select "a", text: "Concourse tasks", count: 0

    create_concourse_agent(@agent)
    get agent_peer_tasks_path(@agent)
    assert_select ".settings__empty", text: /No open tasks/
  end

  test "another person's agent's tasks are not found" do
    other = create_user(name: "Sam").agents.sole
    get agent_peer_tasks_path(other)
    assert_response :not_found
  end
end
