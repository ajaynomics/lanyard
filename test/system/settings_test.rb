require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# Settings in a browser: a small setting saves as it changes and says
# "Saved", long text warns before it is lost, ⌘, opens Settings from
# anywhere, a tool goes off for every agent or for one, and an Always
# answered on an approval card shows in Permissions until removed.
class SettingsTest < ApplicationSystemTestCase
  include AgentTestHelper
  include EmailTestHelper
  include McpTestHelper

  setup do
    install_sidecar_settings
    install_email_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
  end
  teardown do
    remove_sidecar_settings
    remove_email_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "⌘, opens Settings, and choosing a model saves it at once and says Saved" do
    visit root_path
    find("body").send_keys([ :control, "," ])
    assert_current_path settings_path
    assert_selector ".settings-nav__link", text: @agent.name

    click_on @agent.name
    assert_current_path agent_path(@agent)
    select "GPT 6.1 Sol · Subscription", from: "Model"
    assert_selector "#settings_saved > span", text: "Saved", visible: :all, wait: 10 # a save, its redirect and the morph, under a loaded CI
    assert_equal "openai-codex/gpt-6.1-sol", @agent.reload.model
    assert_equal "openai-codex/gpt-6.1-sol", @agent.conversation.definition[:model]
    assert_no_button "Save"
  end

  test "beside the sidebar Settings has no bar above it; the sidebar's first row goes back to the agent's thread" do
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    visit agent_path(@agent)
    assert_selector ".settings__nav"
    assert_no_selector ".app-header", visible: true
    assert_equal 0, page.evaluate_script("Math.round(document.querySelector('.settings__nav').getBoundingClientRect().top)"), "the sidebar starts at the top"

    within(".settings__nav") { click_on "‹ Agents" }
    assert_current_path conversation_path(@agent.conversation)
  end

  test "leaving the instructions with changes unsaved asks first; staying keeps them, Save keeps them for good" do
    visit agent_instructions_path(@agent)
    find("textarea#agent_instructions").fill_in(with: "Be brief.")

    click_on "Tools"
    within("dialog#confirm[open]") do
      assert_text "Leave without saving? Your changes will be lost."
      click_on "Cancel"
    end
    assert_current_path agent_instructions_path(@agent)
    assert_equal "Be brief.", find("textarea#agent_instructions").value

    click_on "Save"
    assert_selector "#flash .flash", text: "Saved. #{@agent.name} follows these from the next message."
    assert_equal "Be brief.", @agent.reload.instructions
    click_on "Tools"
    assert_current_path agent_tools_path(@agent)
    assert_no_selector "dialog#confirm[open]"
  end

  test "a connector's tool goes off for every agent on its page, and another for one agent in that agent's Tools" do
    wiki = create_mcp_server(@agent, name: "wiki", tools: [ mcp_tool("search", description: "Searches the wiki."), mcp_tool("edit") ])
    other = @agent.user.agents.create!(name: "Researcher", instructions: "Research.", model: @agent.model)
    create_conversation(other, durable_id: "13")

    visit connectors_path
    click_on "wiki"
    assert_current_path connector_path(wiki)
    find("label", text: /\Asearch/).click
    assert_selector "#settings_saved > span", text: "Saved", visible: :all, wait: 10 # a save, its redirect and the morph, under a loaded CI
    assert_selector "#connector_tool_search:not(:checked)"
    assert_equal [ "search" ], wiki.reload.disabled_tools
    assert_nil @conversation.tool("mcp__wiki__search")

    visit agent_tools_path(@agent)
    assert_selector "#tool_meter", text: /of 64 tools/
    assert_selector ".ui-row", text: /search.*Off for every agent/m
    assert_selector "#tool_mcp__wiki__search[disabled]"
    find("#tools_filter").fill_in(with: "edit")
    assert_no_selector ".ui-row", text: "Searches the wiki."
    find("label", text: /\Aedit/).click
    assert_selector ".ui-row", text: /edit.*Off for #{@agent.name} only/m
    assert_equal "edit", find("#tools_filter").value, "the search survives the save"

    assert_nil @agent.reload.conversation.tool("mcp__wiki__edit")
    assert other.reload.conversation.tool("mcp__wiki__edit")
  end

  test "an Always answered on an approval card shows in Permissions, and removing it asks again" do
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/12/wakes}).to_return(body: { rung: true }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "assistant", content: "", toolCalls: [ { id: "c1", name: "send_email" } ] } ],
                         cursor: 1, more: false }.to_json)
    arguments = { "to" => [ "hotel@acme.example" ], "subject" => "Friday", "body" => "Two nights." }
    payload = invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: "c1")
    Invocation.receive(@conversation, task_id: payload[:taskId], call_id: "c1", tool: "send_email", arguments: arguments, digest: payload[:digest])

    visit conversation_path(@conversation)
    click_on "Always with hotel@acme.example"
    assert_no_selector ".approval .ui-card__actions"

    visit agent_permissions_path(@agent)
    within("#permissions") do
      assert_selector "li", text: /Send email\s*With hotel@acme.example · added/
      click_on "Remove"
    end
    within("dialog#confirm[open]") { click_on "Remove" }
    assert_text "Nothing yet."
    assert_empty @agent.permissions.reload
  end

  test "New agent shows the address it will get as the name is typed, and makes it" do
    visit new_agent_path
    assert_text "Its name and address can't be changed later."
    fill_in "Name", with: "Garden planner"
    assert_selector "#agent_address_hint strong", text: "garden-planner@#{DurableAssistants::Email.domain}"
    fill_in "Name", with: "Assistant"
    assert_selector "#agent_address_hint strong", text: "assistant-2@#{DurableAssistants::Email.domain}"
    assert_field "Address", with: "assistant-2"
    click_on "Start"
    assert_selector ".chat__title", text: "Assistant"
    assert_equal "assistant-2", @agent.user.agents.order(:id).last.email_name
  end

  test "New agent's address follows the name until the person types their own, which is checked and kept" do
    domain = DurableAssistants::Email.domain
    @agent.user.start_agent("Placeholder", email_name: "taken")
    visit new_agent_path
    assert_text "Its name and address can't be changed later."
    fill_in "Name", with: "Jordan Reyes"
    assert_field "Address", with: "jordan-reyes"

    fill_in "Address", with: "taken"
    assert_selector "#agent_address_hint .field__error", text: "That address is another agent's."
    fill_in "Address", with: "Jordan"
    assert_selector "#agent_address_hint strong", text: "jordan@#{domain}"
    fill_in "Name", with: "Jordan Reyes, work"
    assert_selector "#agent_address_hint strong", text: "jordan@#{domain}"
    assert_field "Address", with: "Jordan"

    click_on "Start"
    assert_selector ".chat__title", text: "Jordan Reyes, work"
    assert_equal "jordan", @agent.user.agents.order(:id).last.email_name
  end

  test "on a phone, the wallet's sign-in puts its buttons under the phrase, which stays on one line" do
    link = Rails.application.config.x.link
    Rails.application.config.x.link = { client_id: "lwlpk_example", client_name: "Lanyard", test_mode: true }
    @agent.user.update!(link_session: { "device_code" => "dev-1", "phrase" => "apple-banana-cherry-date",
      "url" => "https://app.link.com/device/setup", "expires_at" => 10.minutes.from_now.to_i })
    page.current_window.resize_to(390, 844)
    visit settings_wallet_path

    phrase = page.evaluate_script("document.querySelector('.wallet__phrase').getBoundingClientRect().toJSON()")
    done = page.evaluate_script("[...document.querySelectorAll('#wallet_sign_in button')].find(b => b.textContent.trim() === 'Done').getBoundingClientRect().toJSON()")
    words = page.evaluate_script("document.querySelector('#wallet_sign_in .ui-row__label').getBoundingClientRect().toJSON()")
    assert_operator done["top"], :>=, words["bottom"]
    assert_operator words["width"], :>, 300
    assert_in_delta phrase["height"], page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.wallet__phrase')).lineHeight)"), 2
  ensure
    Rails.application.config.x.link = link
    page.current_window.resize_to(1400, 1400)
  end
end
