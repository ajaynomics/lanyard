require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

class Agent::MailAccountTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  setup { @agent = create_user(name: "Alice").agents.sole }
  teardown { remove_fake_passbolt }

  test "it keeps an address, a server and a vault entry's name, with the usual ports, and never a password" do
    account = @agent.create_mail_account!(address: " Desk@Mail.Example.com ", smtp_host: "SMTP.mail.example.com.", vault_entry: "  Agent   mailbox ")
    assert_equal [ "desk@mail.example.com", "smtp.mail.example.com", "Agent mailbox", 587, 993, nil ],
      account.values_at(:address, :smtp_host, :vault_entry, :smtp_port, :imap_port, :forced_bcc)
    assert_not_includes Agent::MailAccount.column_names.join(" "), "password"
    assert_equal "#{@agent.name} <desk@mail.example.com>", account.from
  end

  test "one per agent" do
    @agent.create_mail_account!(address: "desk@example.com", smtp_host: "smtp.example.com", vault_entry: "Mailbox")
    second = Agent::MailAccount.new(agent: @agent, address: "other@example.com", smtp_host: "smtp.example.com", vault_entry: "Mailbox")
    assert_not second.valid?
    assert_includes second.errors[:agent_id], "has already been taken"
  end

  test "addresses are one plain address, and servers a plain name with no sign-in, scheme or port" do
    { address: [ "Desk <desk@example.com>", "a@b@example.com", "desk@example.com, x@example.net", "desk@localhost", "desk" ],
      forced_bcc: [ "a@example.com;b@example.com", "records@ example.com" ],
      smtp_host: [ "user:pw@smtp.example.com", "smtp://smtp.example.com", "smtp.example.com:587", "smtp.example.com/x", "localhost", "-smtp.example.com" ],
      imap_host: [ "imap.example.com:993" ] }.each do |attribute, values|
      values.each do |value|
        account = Agent::MailAccount.new(agent: @agent, address: "desk@example.com", smtp_host: "smtp.example.com", vault_entry: "Mailbox", attribute => value)
        assert_not account.valid?, "#{attribute} #{value.inspect} was taken"
        assert account.errors[attribute].any?, "#{attribute} #{value.inspect}: #{account.errors.full_messages}"
      end
    end
  end

  test "the incoming server is the mail server or one beside it in the same domain, as the one saved sign-in names the mail server" do
    { "smtp.example.com" => %w[ smtp.example.com imap.example.com mail.example.com ],
      "smtp.mail.example.com" => %w[ imap.mail.example.com ] }.each do |smtp, imaps|
      imaps.each do |imap|
        account = Agent::MailAccount.new(agent: @agent, address: "desk@example.com", smtp_host: smtp, imap_host: imap, vault_entry: "Mailbox")
        assert account.valid?, "#{imap} beside #{smtp}: #{account.errors.full_messages}"
      end
    end
    { "smtp.example.com" => %w[ imap.elsewhere.example imap.mail.example.com example.com imap.example.com.evil.example ],
      "smtp.example" => %w[ imap.example ] }.each do |smtp, imaps|
      imaps.each do |imap|
        account = Agent::MailAccount.new(agent: @agent, address: "desk@example.com", smtp_host: smtp, imap_host: imap, vault_entry: "Mailbox")
        assert_not account.valid?, "#{imap} beside #{smtp} was taken"
        assert_includes account.errors[:imap_host], "must be #{smtp} or a server beside it, such as imap.#{smtp.split(".", 2).last}"
      end
    end
  end

  test "the vault entry's name is at most 200 characters, and the ports are ports" do
    account = Agent::MailAccount.new(agent: @agent, address: "desk@example.com", smtp_host: "smtp.example.com", vault_entry: "x" * 201, smtp_port: 0)
    assert_not account.valid?
    assert account.errors[:vault_entry].any?
    assert account.errors[:smtp_port].any?
    account.assign_attributes(vault_entry: "x" * 200, smtp_port: 465)
    assert account.valid?, account.errors.full_messages.to_sentence
  end

  test "it is usable only where the agent can read the vault" do
    @agent.create_mail_account!(address: "desk@example.com", smtp_host: "smtp.example.com", vault_entry: "Mailbox")
    assert_not @agent.own_mail?
    install_fake_passbolt(name: "Mailbox", uri: "smtp.example.com")
    assert @agent.reload.own_mail?
    assert_empty passbolt_calls, "nothing is read from the vault until a message is sent"
  end

  test "it goes with its agent" do
    @agent.create_mail_account!(address: "desk@example.com", smtp_host: "smtp.example.com", vault_entry: "Mailbox")
    @agent.destroy!
    assert_not Agent::MailAccount.exists?(agent_id: @agent.id) # tenancy-ok: the deleted agent's own row
  end

  test "one sending account per agent, with any number it only reads beside it, which need an incoming server and never a mail server or Bcc" do
    sending = @agent.create_mail_account!(address: "desk@example.com", smtp_host: "smtp.example.com", vault_entry: "Mailbox")
    old = @agent.mail_accounts.create!(read_only: true, address: "old@example.com", imap_host: "imap.old.example.com", vault_entry: "Old")
    @agent.mail_accounts.create!(read_only: true, address: "older@example.com", imap_host: "imap.old.example.com", vault_entry: "Older", folder_names: " INBOX ,Archive,, ")
    assert_equal sending, @agent.reload.mail_account
    assert_equal "INBOX, Sent, Drafts", old.folder_names
    assert_equal [ "INBOX", "Archive" ], @agent.mail_accounts.find_by!(address: "older@example.com").folder_list
    assert_includes Agent::MailAccount.new(agent: @agent, address: "two@example.com", smtp_host: "smtp.example.com", vault_entry: "M").tap(&:valid?).errors[:agent_id], "has already been taken"

    bad = Agent::MailAccount.new(agent: @agent, read_only: true, address: "old@example.com", smtp_host: "smtp.example.com", forced_bcc: "x@example.com",
      vault_entry: "Old", folder_names: "INBOX, *")
    assert_not bad.valid?
    assert_equal %w[ address folder_names forced_bcc imap_host smtp_host ], bad.errors.attribute_names.map(&:to_s).sort
    assert_raises(ActiveRecord::ReadonlyAttributeError) { old.update!(read_only: false) }
  end
end
