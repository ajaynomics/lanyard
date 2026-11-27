require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A workspace's own Passbolt user (Workspace::VaultUser): its agents read and
# save as it, unless an agent has its own; without one they are the install's
# shared user, as before. Every way the app reads the vault for an agent goes
# through the one precedence (DurableAssistants::Passbolt.connection_for).
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

  SERVER = "https://vault.example.test".freeze

  test "its own server is an https address outside this server, set with its user, and forgotten with it" do
    assert_not @acorn.update(passbolt_url: SERVER)
    [ "http://vault.example.test", "https://127.0.0.1", "vault" ].each do |address|
      assert_not @acorn.update(passbolt_url: address, passbolt_private_key: KEY, passbolt_passphrase: PASS), address
    end
    assert @acorn.update(passbolt_url: " #{SERVER} ", passbolt_private_key: KEY, passbolt_passphrase: PASS)
    assert_equal SERVER, @acorn.reload.passbolt_url
    @acorn.forget_vault_user
    assert_nil @acorn.reload.passbolt_url
  end

  test "a workspace on its own server is read and saved only there, as its own user, never on the install's" do
    install_fake_native_vault
    @acorn.update!(passbolt_url: SERVER, passbolt_private_key: KEY, passbolt_passphrase: PASS)
    found = DurableAssistants::Passbolt.find_by_name(@agent, "Desk")
    DurableAssistants::Passbolt.sign_in(@agent, found.id)
    DurableAssistants::Passbolt.sign_in_by_name(@acorn, "Desk")
    DurableAssistants::Passbolt.save(@agent, name: "Library", address: "library.example", username: "ada", password: "made-up")
    DurableAssistants::Passbolt.fill(@agent, found.id, username: "ada", password: "made-up")
    @agent.create_mail_account!(address: "ada@mail.example.com", smtp_host: "mail.example.com", vault_entry: "Desk").send(:sign_in)

    assert_operator passbolt_servers.size, :>=, 8
    assert_equal [ "vault.example.test" ], passbolt_servers.uniq
    assert_equal [ passbolt_user(KEY, PASS) ], (passbolt_users + @native_reads.map(&:last)).uniq
  end

  test "a workspace whose own server has no whole user refuses by name, and nothing is read anywhere" do
    install_fake_native_vault
    [ {}, { passbolt_private_key: KEY } ].each do |half| # only by hand: its page takes the server with its user
      @acorn.update_columns(passbolt_url: SERVER, passbolt_private_key: nil, passbolt_passphrase: nil, **half)
      assert_not DurableAssistants::Passbolt.configured?(@agent.reload)
      [ -> { DurableAssistants::Passbolt.sign_ins(@agent) }, -> { DurableAssistants::Passbolt.sign_in_by_name(@acorn, "Desk") },
        -> { DurableAssistants::Passbolt.save(@agent, name: "Library", address: "library.example", username: "ada", password: "made-up") },
        -> { DurableAssistants::Passbolt.fill(@agent, "7f0c", username: "ada", password: "made-up") } ].each do |call|
        error = assert_raises(DurableAssistants::Passbolt::MissingVaultUser) { call.call }
        assert_equal "Acorn's own password manager has no user set, so nothing is read from it or any other.", error.message
      end
    end
    assert_empty passbolt_servers
  end

  # Checked when it was saved is not enough: a public name can be pointed at
  # this server or its private network afterwards.
  test "its own server's name is resolved before every call, and one that leads inside is refused with no call made" do
    install_fake_native_vault
    @acorn.update!(passbolt_url: SERVER, passbolt_private_key: KEY, passbolt_passphrase: PASS)
    [ "127.0.0.1", "10.0.0.5", "169.254.169.254" ].each do |inside|
      resolve_every_name_to inside
      [ -> { DurableAssistants::Passbolt.sign_ins(@agent) }, -> { DurableAssistants::Passbolt.sign_in_by_name(@acorn, "Desk") },
        -> { DurableAssistants::Passbolt.sign_in(@agent, "7f0c") },
        -> { DurableAssistants::Passbolt.save(@agent, name: "Library", address: "library.example", username: "ada", password: "made-up") },
        -> { DurableAssistants::Passbolt.fill(@agent, "7f0c", username: "ada", password: "made-up") } ].each do |call|
        error = assert_raises(DurableAssistants::Passbolt::Error, inside) { call.call }
        assert_equal "Acorn's own password manager was not called: vault.example.test is on this server or its private network.", error.message
      end
      assert_not @acorn.update(passbolt_url: "https://other-vault.example.test"), inside
      assert_equal [ "Server can't be used: other-vault.example.test is on this server or its private network" ],
        @acorn.errors.full_messages_for(:passbolt_url)
      @acorn.restore_attributes
    end
    assert_empty passbolt_servers

    resolve_every_name_to "203.0.113.10"
    DurableAssistants::Passbolt.sign_ins(@agent)
    DurableAssistants::Passbolt.save(@agent, name: "Library", address: "library.example", username: "ada", password: "made-up")
    assert_equal [ "vault.example.test" ] * 3, passbolt_servers # the list, save's own list, and its save
  end

  test "without its own server a workspace is read on the install's; an agent's own user goes to its workspace's server" do
    install_fake_native_vault
    @acorn.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
    DurableAssistants::Passbolt.sign_ins(@agent)
    DurableAssistants::Passbolt.sign_ins(@elsewhere)
    assert_equal [ "passwords.example" ] * 2, passbolt_servers

    @acorn.update!(passbolt_url: SERVER)
    @agent.update!(passbolt_private_key: KEY.sub("acorn", "ada"), passbolt_passphrase: "ada-made-up")
    DurableAssistants::Passbolt.sign_ins(@agent.reload)
    DurableAssistants::Passbolt.sign_ins(@elsewhere)
    assert_equal [ "passwords.example" ] * 3, passbolt_calls.lines.grep(/^SERVER /).map { URI(it.split.last).host }
    assert_equal [ [ "vault.example.test", passbolt_user(KEY.sub("acorn", "ada"), "ada-made-up") ] ], @native_reads
  end

  test "what is read from or saved to its own server is never kept in the database, and its user only encrypted" do
    install_fake_native_vault
    @acorn.update!(passbolt_url: SERVER, passbolt_private_key: KEY, passbolt_passphrase: PASS)
    DurableAssistants::Passbolt.sign_in_by_name(@agent, "Desk")
    DurableAssistants::Passbolt.save(@agent, name: "Library", address: "library.example", username: "ada", password: "made-up-library")

    database = ActiveRecord::Base.connection
    stored = database.tables.flat_map { database.select_rows("SELECT * FROM #{database.quote_table_name(it)}") }.flatten.map { it.to_s.b }.join("\n")
    assert_includes stored, SERVER.b
    [ PASSWORD, ANSWER, "made-up-library", "BEGIN PGP", PASS ].each { assert_not_includes stored, it.b }
  end
end
