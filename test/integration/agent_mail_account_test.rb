require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# An agent's own mail account (#77, docs/email.md): send_email goes from its
# address through its server, signed in with the vault entry for that one
# message, and every message carries the owner's forced Bcc. The fake
# `passbolt` command is the only stand-in; the sidecar's endpoints, the
# ledger, the job and the mailer run for real. Action Mailer's test delivery
# keeps each message with the settings it would have reached the server
# with, the install's merged with the message's own.
class AgentMailAccountTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  KEY = PassboltTestHelper::PASSWORD
  SERVER = "smtp.mail.example.com"
  BCC = "records@example.org"
  PDF = "%PDF-1.7\n\xE2\xE3\xCF\xD3 plan".b.freeze

  setup do
    ActionMailer::Base.deliveries.clear
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SERVER)
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @account = @agent.create_mail_account!(address: "desk@mail.example.com", display_name: "Travel desk", smtp_host: SERVER,
      vault_entry: "Agent mailbox", forced_bcc: BCC)
  end
  teardown do
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "it sends from its own address through its own server, signed in for that message alone" do
    install_settings = ActionMailer::Base.smtp_settings.deep_dup
    done = run_call(mail_to("alice@example.com"))

    assert_equal false, done["isError"], done.inspect
    mail = ActionMailer::Base.deliveries.sole
    assert_equal "Travel desk <desk@mail.example.com>", mail[:from].to_s
    assert_equal({ address: SERVER, port: 587, domain: "mail.example.com", user_name: "maya", password: KEY, authentication: :plain,
      tls: false, ssl: false, enable_starttls: :always, enable_starttls_auto: false }, mail.delivery_method.settings.except(:location, :arguments))
    assert_includes passbolt_calls, "get resource"
    assert_equal install_settings, ActionMailer::Base.smtp_settings, "the install's own settings are untouched"
    assert_nil AgentMailer.smtp_settings[:password]
  end

  test "on port 465 it uses TLS from the start, never STARTTLS" do
    @account.update!(smtp_port: 465)
    run_call(mail_to("alice@example.com"))

    assert_equal({ port: 465, tls: true, ssl: true, enable_starttls: false, enable_starttls_auto: false },
      ActionMailer::Base.deliveries.sole.delivery_method.settings.slice(:port, :tls, :ssl, :enable_starttls, :enable_starttls_auto))
  end

  test "the forced Bcc is on every message, attachments and replies too, and in no header the recipients read" do
    upload "/home/agent/plan.pdf", PDF
    run_call(mail_to("alice@example.com", attachments: [ "/home/agent/plan.pdf" ]), call_id: "c1")
    run_call(mail_to("alice@example.com", subject: "Re: Trip", in_reply_to: "abc@example.com"), call_id: "c2")

    first, reply = ActionMailer::Base.deliveries
    assert_equal [ PDF ], first.attachments.map { it.decoded.b }
    assert_equal "abc@example.com", reply.in_reply_to
    [ first, reply ].each do |mail|
      assert_equal [ BCC ], mail.bcc
      assert_equal [ "alice@example.com", BCC ], mail.smtp_envelope_to
      assert_not_includes mail.encoded, BCC
    end
  end

  test "the agent's own Cc and Bcc go as it set them, and the forced Bcc is added beside them, out of its sight" do
    declared = @conversation.definition[:tools].find { it[:name] == "send_email" }
    assert_equal false, declared.dig(:parameters, "additionalProperties")
    assert_equal %w[ attachments bcc body cc in_reply_to note_to_approver subject to ], declared.dig(:parameters, "properties").keys.sort
    assert_not_includes @conversation.definition.to_json, BCC

    done = run_call(mail_to("alice@example.com").merge("cc" => [ "bob@example.com" ], "bcc" => [ "carol@example.com" ]))
    assert_equal false, done["isError"], done.inspect

    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "alice@example.com" ], mail.to
    assert_equal [ "bob@example.com" ], mail.cc
    assert_equal [ "carol@example.com", BCC ], mail.bcc
    assert_equal [ "alice@example.com", "bob@example.com", "carol@example.com", BCC ], mail.smtp_envelope_to
    assert_not_includes mail.encoded, BCC
    assert_not_includes mail.encoded, "carol@example.com"
    assert_not_includes done.to_json, BCC
    assert_not_includes @conversation.invocations.reload.map(&:attributes).to_json, BCC
  end

  test "the password reaches no result, ledger row, message, log line or definition" do
    log = capture_log do
      done = run_call(mail_to("alice@example.com"))
      assert_equal false, done["isError"], done.inspect
      assert_not_includes done.to_json, KEY
    end
    assert_equal KEY, ActionMailer::Base.deliveries.sole.delivery_method.settings[:password], "the password was used"
    assert_match "InvocationCallJob", log, "the log was read"
    assert_match "Delivered mail", log, "the mailer's own lines were read too"
    assert_not_includes log, KEY
    assert_not_includes @conversation.invocations.reload.map(&:attributes).to_json, KEY
    assert_not_includes @conversation.messages.reload.map(&:attributes).to_json, KEY
    assert_not_includes @conversation.definition.to_json, KEY
    assert_not_includes @agent.reload.definition(@conversation.tools).to_json, KEY
    assert_not_includes Agent::MailAccount.connection.select_all("select * from agent_mail_accounts where agent_id = #{@agent.id}").to_a.to_json, KEY # tenancy-ok: the test's own agent
    assert_not_includes @account.inspect, KEY
  end

  test "an entry saved for another server is refused, and nothing is sent" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Agent mailbox", uri: "https://webmail.elsewhere.example")
    done = run_call(mail_to("alice@example.com"))

    assert done["isError"]
    assert_equal "Your mail account couldn't sign in, so nothing was sent: Agent mailbox is saved for webmail.elsewhere.example, not #{SERVER}, so it is not sent there.",
      done.dig("result", "error")
    assert_empty ActionMailer::Base.deliveries
  end

  test "without a password manager it sends as before, from its address here, and the Bcc still goes" do
    remove_fake_passbolt
    run_call(mail_to("alice@example.com"))

    mail = ActionMailer::Base.deliveries.sole
    assert_equal "#{@agent.name} <#{@agent.email_address}>", mail[:from].to_s
    assert_nil mail.delivery_method.settings[:user_name]
    assert_equal [ BCC ], mail.bcc
  end

  test "without an account nothing changes: its address here, the install's server, no Bcc" do
    @account.destroy!
    run_call(mail_to("alice@example.com"))

    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ @agent.email_address ], mail.from
    assert_empty mail.delivery_method.settings.slice(:address, :user_name, :password)
    assert_nil mail.bcc
  end

  test "its own account gives it send_email where the install has no email; neither, and it has none" do
    with_setting(:mail, :domain, nil) do
      assert_includes @conversation.reload.definition[:tools].pluck(:name), "send_email"
      run_call(mail_to("alice@example.com"))
      assert_equal [ "desk@mail.example.com" ], ActionMailer::Base.deliveries.sole.from

      remove_fake_passbolt
      assert_not_includes @agent.reload.conversation.definition[:tools].pluck(:name), "send_email"
    end
  end

  test "a notice that it needs the person goes the install's way, without the Bcc" do
    mail = AgentMailer.needs_you(@conversation, to: "alice@example.com", title: "Travel needs you", body: "Allow send_email?").deliver_now
    assert_equal [ @agent.email_address ], mail.from
    assert_nil mail.bcc
    assert_nil mail.delivery_method.settings[:user_name]
    assert_not_includes passbolt_calls, "get resource"

    @account.update!(primary: true)
    remove_fake_passbolt
    mail = AgentMailer.needs_you(@conversation.reload, to: "alice@example.com", title: "Travel needs you", body: "Allow send_email?").deliver_now
    assert_equal [ @agent.email_address ], mail.from, "as its only address too: it goes to the owner alone, and the vault may be down"
  end

  test "as its only address, an account it can't sign in to refuses, and nothing goes from its address here" do
    @account.update!(primary: true)
    remove_fake_passbolt
    done = run_call(mail_to("alice@example.com"))

    assert done["isError"], done.inspect
    assert_equal "Your mail account couldn't sign in, so nothing was sent: #{@agent.name} can't read the password manager, " \
      "and it sends only from desk@mail.example.com.", done.dig("result", "error")
    assert_empty ActionMailer::Base.deliveries
  end

  test "as its only address, an entry it can't use refuses too, and nothing goes from its address here" do
    @account.update!(primary: true)
    remove_fake_passbolt
    install_fake_passbolt(name: "Agent mailbox", uri: "https://webmail.elsewhere.example")
    done = run_call(mail_to("alice@example.com"))

    assert done["isError"], done.inspect
    assert_match "so nothing was sent", done.dig("result", "error")
    assert_empty ActionMailer::Base.deliveries
  end

  test "as its only address, it sends from the account as before" do
    @account.update!(primary: true)
    done = run_call(mail_to("alice@example.com"))

    assert_equal false, done["isError"], done.inspect
    assert_equal "Travel desk <desk@mail.example.com>", ActionMailer::Base.deliveries.sole[:from].to_s
  end

  test "its prompt names the account's address as its own, and never its address here" do
    install = @agent.email_address
    assert_match "your email address is #{install}", @agent.identity

    @account.update!(primary: true)
    @agent.reload
    assert_match "your email address is desk@mail.example.com.", @agent.identity
    definition = @agent.definition(@conversation.tools).to_json
    assert_not_includes definition, install
    assert_not_includes definition, "@#{DurableAssistants::Email.domain}"
  end

  test "change_yourself takes instructions and their scope alone, so the agent can't make the account its only address, or stop it being so" do
    declared = @conversation.definition[:lookup].find { it[:name] == "change_yourself" }
    assert_equal %w[ instructions scope note_to_approver ], declared.dig(:parameters, "properties").keys
    assert_equal false, declared.dig(:parameters, "additionalProperties")

    @agent.update!(instructions: "Help.\n\nYour email address is #{@agent.email_address}.")
    assert_not @account.reload.primary?
  end

  private
    def mail_to(address, subject: "Trip", in_reply_to: nil, attachments: nil)
      { "to" => [ address ], "subject" => subject, "body" => "Two nights.", "in_reply_to" => in_reply_to, "attachments" => attachments }.compact
    end

    def upload(path, bytes, call_id: "c1")
      post "/agent/uploads", headers: rails_bearer, as: :json, params: { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s,
        conversationId: @conversation.durable_id, taskId: 7, callId: call_id, tool: "send_email", path: path, bytes: Base64.strict_encode64(bytes) }
    end

    def invoke(arguments, call_id:)
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    # Mail to the install's own people goes at once; an outside call runs from
    # a job once claimed, and the replay then reads its result.
    def run_call(arguments, call_id: "c1")
      with_setting(:access, :emails, [ "alice@example.com", "bob@example.com", "carol@example.com" ]) do
        invoke(arguments, call_id: call_id)
        perform_enqueued_jobs(only: InvocationCallJob)
        invoke(arguments, call_id: call_id)
      end
    end

    def capture_log
      output = StringIO.new
      previous, mailer = Rails.logger, ActionMailer::Base.logger
      Rails.logger = ActiveSupport::BroadcastLogger.new(previous, ActiveSupport::Logger.new(output).tap { it.level = :debug })
      ActiveJob::Base.logger = ActionController::Base.logger = ActionMailer::Base.logger = Rails.logger
      yield
      output.string
    ensure
      Rails.logger = ActiveJob::Base.logger = ActionController::Base.logger = previous
      ActionMailer::Base.logger = mailer
    end
end
