require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::PromptsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person saves, edits and removes a prompt, and the settings list it" do
    post agent_prompts_path(@agent), params: { prompt: { name: "review", description: "", body: "Review $1" } }
    assert_redirected_to agent_prompts_path(@agent)
    prompt = @agent.prompts.sole
    follow_redirect!
    assert_select ".ui-row", %r{/review.*Review \$1}m

    patch agent_prompt_path(@agent, prompt), params: { prompt: { body: "Check $@" } }
    assert_equal "Check $@", prompt.reload.body

    delete agent_prompt_path(@agent, prompt)
    assert_empty @agent.prompts
  end

  test "a prompt named for a built-in command is refused, with the reason" do
    post agent_prompts_path(@agent), params: { prompt: { name: "stop", body: "x" } }
    assert_response :unprocessable_entity
    assert_select ".flash", /one of the built-in commands/
  end

  test "another person's agent and prompts are not found" do
    theirs = create_user(name: "Mallory").agents.sole
    prompt = theirs.prompts.create!(name: "theirs", body: "x")

    get edit_agent_prompt_path(theirs, prompt)
    assert_response :not_found
    delete agent_prompt_path(@agent, prompt)
    assert_response :not_found
    assert theirs.prompts.exists?
  end
end
