require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A workspace's own Passbolt user (Workspace::VaultUser): its agents read and
# save as it, unless an agent has its own; without one they are the install's
# shared user, as before. Every way the app reads the vault for an agent goes
# through the one precedence (DurableAssistants::Passbolt.key_for).
class WorkspaceVaultTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  KEY = PassboltTestHelper::PRIVATE_KEY.sub("synthetic", "acorn").freeze
  PASS = "acorn-made-up-passphrase".freeze

  setup do
    install_fake_passbolt(name: "Desk", uri: "https://mail.example.com")
    @alice = create_user(name: "Alice")
    @acorn = Workspace.create!(name: "Acorn")
    @acorn.memberships.create!(user: @alice, role: "owner")
    @agent = @alice.start_agent("Ada", workspace: @acorn)
    @elsewhere = @alice.agents.find_by!(workspace: @alice.personal_workspace)
  end
  teardown { remove_fake_passbolt }

  test "a workspace's own user is kept encrypted, set as a pair, and named only as set" do
    @acorn.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
    stored = Workspace.connection.select_one("SELECT passbolt_private_key, passbolt_passphrase FROM workspaces WHERE id = #{@acorn.id}")
    assert_no_match "acorn-made-up", stored.values.join

    assert @acorn.vault_user?
    assert_not @acorn.update(passbolt_private_key: KEY, passbolt_passphrase: "")
    assert_match(/passphrase/i, @acorn.errors.full_messages.to_sentence)
    @acorn.reload.forget_vault_user
    assert_not @acorn.reload.vault_user?
  end

  test "its agents read as the workspace's user; an agent's own pair comes first; elsewhere the install's" do
    @acorn.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
    DurableAssistants::Passbolt.sign_ins(@agent)
    DurableAssistants::Passbolt.sign_ins(@elsewhere)
    @agent.update!(passbolt_private_key: "-----BEGIN PGP PRIVATE KEY BLOCK-----\nada\n-----END PGP PRIVATE KEY BLOCK-----",
      passbolt_passphrase: "ada-made-up")
    DurableAssistants::Passbolt.sign_ins(@agent)

    assert_equal [ passbolt_user(KEY, PASS), passbolt_user(PRIVATE_KEY, PASSPHRASE), passbolt_user(@agent.passbolt_private_key, "ada-made-up") ],
      passbolt_users
  end

  test "half a pair is none: the install's user, as before" do
    @acorn.update_columns(passbolt_private_key: KEY) # only by hand: the settings page takes both or neither
    DurableAssistants::Passbolt.sign_ins(@agent.reload)
    assert_equal [ passbolt_user(PRIVATE_KEY, PASSPHRASE) ], passbolt_users
  end

  test "with its own user the workspace has saved sign-ins where the install has no shared one" do
    with_setting(:passbolt, :private_key, nil) do
      assert_not DurableAssistants::Passbolt.configured?(@agent)
      @acorn.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
      assert DurableAssistants::Passbolt.configured?(@agent.reload)
      assert_not DurableAssistants::Passbolt.configured?(@elsewhere)
    end
  end

  # Sign-ins, mail and calendar passwords, a Telegram token, an API key and a
  # sign-in link all reach the vault through the agent: none reads the
  # install's folders while its workspace has its own user.
  test "every reader of the vault for an agent in the workspace goes as the workspace's user" do
    @acorn.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
    found = DurableAssistants::Passbolt.find_by_name(@agent, "Desk")
    DurableAssistants::Passbolt.sign_in(@agent, found.id)
    DurableAssistants::Passbolt.save(@agent, name: "Library", address: "library.example", username: "ada", password: "made-up")
    DurableAssistants::Passbolt.fill(@agent, found.id, username: "ada", password: "made-up")
    @agent.create_mail_account!(address: "ada@mail.example.com", smtp_host: "mail.example.com", vault_entry: "Desk").send(:sign_in)
    bot = @agent.create_telegram_bot!(vault_entry: "Desk", username: "ada_example_bot")
    assert_raises(TelegramBot::SignInError) { bot.send(:token) } # saved for mail.example.com, so it is read and refused

    assert_operator passbolt_users.size, :>=, 8
    assert_equal [ passbolt_user(KEY, PASS) ], passbolt_users.uniq
  end
end
