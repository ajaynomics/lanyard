require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

# An agent's Telegram bot is the workspace owner's to connect: by the name of
# the vault entry that holds its token, which the app reads to tell Telegram
# where to post and never shows or keeps.
class Agents::TelegramBotsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper

  TOKEN = "123456789:AAFakeTokenForTests_only-0123456789abcd".freeze
  API = "https://api.telegram.org/bot#{TOKEN}".freeze

  setup do
    install_fake_passbolt(name: "Desk bot", uri: "https://api.telegram.org", password: TOKEN)
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @me = stub_request(:post, "#{API}/getMe").to_return(body: { ok: true, result: { id: 123456789, is_bot: true, first_name: "Desk", username: "desk_example_bot" } }.to_json)
  end
  teardown { remove_fake_passbolt }

  test "the owner connects a bot by its vault entry's name; Telegram is told the webhook and its secret; Disconnect removes it" do
    get agent_channels_path(@agent)
    assert_select "#telegram", /Off/
    assert_select "#telegram input[name='telegram_bot[vault_entry]']"
    assert_select "#telegram input[type=password]", count: 0

    hook = stub_request(:post, "#{API}/setWebhook").to_return(body: { ok: true, result: true }.to_json)
    patch agent_telegram_bot_path(@agent), params: { telegram_bot: { vault_entry: " Desk bot " } }
    assert_redirected_to agent_channels_path(@agent)
    bot = @agent.reload.telegram_bot
    assert_equal [ "Desk bot", "desk_example_bot" ], bot.values_at(:vault_entry, :username)
    assert_requested @me
    assert_requested hook
    assert_requested(:post, "#{API}/setWebhook") do |request|
      JSON.parse(request.body) == { "url" => "http://localhost/telegram/#{bot.id}", "secret_token" => bot.webhook_secret,
        "allowed_updates" => [ "message" ] }
    end

    follow_redirect!
    assert_select "#telegram", /Connected/
    assert_select "#telegram", /@desk_example_bot/
    assert_not_includes response.body, TOKEN.split(":").last
    assert_not_includes response.body, bot.webhook_secret

    unhook = stub_request(:post, "#{API}/deleteWebhook").to_return(body: { ok: true, result: true }.to_json)
    delete agent_telegram_bot_path(@agent)
    assert_redirected_to agent_channels_path(@agent)
    assert_nil @agent.reload.telegram_bot
    assert_requested unhook
  end

  test "an entry that isn't there, or Telegram refusing the token, keeps nothing and says why" do
    patch agent_telegram_bot_path(@agent), params: { telegram_bot: { vault_entry: "Nope" } }
    assert_response :unprocessable_entity
    assert_select "#telegram [role=alert]", /Nothing called Nope is shared with the agents/
    assert_select "#telegram input[name='telegram_bot[vault_entry]'][value='Nope']"
    assert_nil @agent.reload.telegram_bot

    stub_request(:post, "#{API}/getMe").to_return(status: 401, body: { ok: false, error_code: 401, description: "Unauthorized" }.to_json)
    patch agent_telegram_bot_path(@agent), params: { telegram_bot: { vault_entry: "Desk bot" } }
    assert_response :unprocessable_entity
    assert_select "#telegram [role=alert]", /Telegram refused: Unauthorized/
    assert_nil @agent.reload.telegram_bot
  end

  test "not there without a password manager" do
    remove_fake_passbolt
    get agent_channels_path(@agent)
    assert_select "#telegram", count: 0
    patch agent_telegram_bot_path(@agent), params: { telegram_bot: { vault_entry: "Desk bot" } }
    assert_response :not_found
  end

  test "another member of a shared workspace neither sees nor changes it" do
    owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: owner, role: "owner")
    agent = shared.agents.create!(user: owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    agent.create_telegram_bot!(vault_entry: "Desk bot", username: "desk_example_bot")
    shared.memberships.create!(user: create_user(name: "Bob"), role: "member")
    reset!
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get workspace_path(shared)

    get agent_channels_path(agent)
    assert_response :success
    assert_select "#telegram", count: 0
    patch agent_telegram_bot_path(agent), params: { telegram_bot: { vault_entry: "Other" } }
    assert_response :not_found
    delete agent_telegram_bot_path(agent)
    assert_response :not_found
    assert_equal "Desk bot", agent.reload.telegram_bot.vault_entry
  end
end
