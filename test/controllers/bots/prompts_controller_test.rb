require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Bots::PromptsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person saves, edits and removes a prompt, and the settings list it" do
    post bot_prompts_path(@bot), params: { prompt: { name: "review", description: "", body: "Review $1" } }
    assert_redirected_to bot_path(@bot, anchor: "prompts")
    prompt = @bot.prompts.sole
    follow_redirect!
    assert_select "#prompts .list__item", %r{/review.*Review \$1}m

    patch bot_prompt_path(@bot, prompt), params: { prompt: { body: "Check $@" } }
    assert_equal "Check $@", prompt.reload.body

    delete bot_prompt_path(@bot, prompt)
    assert_empty @bot.prompts
  end

  test "a prompt named for a built-in command is refused, with the reason" do
    post bot_prompts_path(@bot), params: { prompt: { name: "stop", body: "x" } }
    assert_response :unprocessable_entity
    assert_select ".flash", /one of the built-in commands/
  end

  test "another person's bot and prompts are not found" do
    theirs = create_user(name: "Mallory").bots.sole
    prompt = theirs.prompts.create!(name: "theirs", body: "x")

    get edit_bot_prompt_path(theirs, prompt)
    assert_response :not_found
    delete bot_prompt_path(@bot, prompt)
    assert_response :not_found
    assert theirs.prompts.exists?
  end
end
