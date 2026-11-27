require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"
require_relative "../../test_helpers/voipms_test_helper"

class Tool::PhoneNumberSettingsTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper
  include VoipmsTestHelper
  include ActiveJob::TestHelper

  READ = "phone_number_settings"
  CHANGE = "change_phone_number_settings"
  NUMBER = "6475550123"
  OTHER = "4165550100"
  PIN = "fake-mailbox-pin"
  API_KEY = "synthetic-api-password"

  setup do
    install_voipms_settings
    @person = create_user(name: "Maya")
    @agent = @person.agents.sole
    @agent.update!(phone_number: NUMBER)
    @conversation = create_conversation(@agent)
  end

  teardown do
    remove_fake_passbolt
    remove_voipms_settings
  end

  test "the tools are picked one by one and looked up, not declared" do
    declared = @conversation.definition[:tools].pluck(:name)
    count = @agent.tool_count
    starters = Dir[Rails.root.join("config/agents/*/agent.yml")].flat_map { YAML.safe_load_file(it).fetch("tools") }
    assert_empty starters & [ READ, CHANGE ]

    [ READ, CHANGE ].each do |name|
      assert_not_includes @agent.tool_names, name
      assert Tool::Catalog.find(name)
      enable(name)
      assert @conversation.reload.tool(name)
      assert_not @conversation.declares?(name)
    end
    assert_equal declared, @conversation.definition[:tools].pluck(:name)
    assert_equal count, @agent.tool_count
    assert_operator count, :<=, Agent::TOOL_LIMIT
  end

  test "reading the agent's number shows the routing, SMS and mailbox settings but no secrets or URLs" do
    forms = stub_settings
    result = run_tool(READ)

    assert_equal({ number: NUMBER, routing: "voicemail:101",
      sms: { enabled: true, forward_enabled: true, forward: "9055550100", email_enabled: false, email: "", url_callback_enabled: true,
             webhook_enabled: true, smpp_enabled: false },
      voicemail: { mailbox: "101", email: "old-vm@example.com", attach_message: true, email_attachment_format: "mp3" } }, result)
    assert_private result
    assert_equal [ form("getDIDsInfo", "did" => NUMBER), form("getVoicemails", "mailbox" => "101") ], forms
  end

  test "explicit reads and lists use the calling workspace account, never the other workspace's account" do
    pilot = Workspace.make(name: "Pilot", owner: @person)
    pilot.update!(voipms_vault_entry: "Pilot voip.ms")
    pilot.update!(passbolt_private_key: "pilot-key", passbolt_passphrase: "pilot-passphrase")
    stranger = create_user(name: "Sam")
    stranger.personal_workspace.update!(voipms_vault_entry: "Different voip.ms")
    stranger.agents.sole.update!(phone_number: OTHER)
    install_fake_passbolt(name: "Pilot voip.ms", uri: "https://voip.ms", username: "pilot@example.com", password: "synthetic-pilot-key")
    @agent = pilot.agents.create!(user: @person, name: "Miles", instructions: "Help.", model: @agent.model)
    @conversation = create_conversation(@agent, durable_id: "13")
    forms = stub_voipms do |fields|
      rows = case fields["did"]
      when OTHER then [ did, did(did: OTHER, voicemail: "") ]
      when nil then [ did, did(did: OTHER, voicemail: "") ]
      else [ did ]
      end
      { status: "success", dids: rows }
    end

    assert_equal OTHER, run_tool(READ, { "number" => OTHER }, id: "other").fetch(:number)
    result = run_tool(READ, { "list" => true }, id: "list")
    first = { number: NUMBER, routing: "voicemail:101", voicemail: "101", sms_enabled: true, sms_forward_enabled: true,
      sms_forward: "9055550100", sms_email_enabled: false, sms_email: "" }
    assert_equal({ numbers: [ first, first.merge(number: OTHER, voicemail: nil) ] }, result)
    assert_private result
    assert_equal [
      { "api_username" => "pilot@example.com", "api_password" => "synthetic-pilot-key", "method" => "getDIDsInfo", "did" => OTHER },
      { "api_username" => "pilot@example.com", "api_password" => "synthetic-pilot-key", "method" => "getDIDsInfo" }
    ], forms
    assert_equal [ passbolt_user("pilot-key", "pilot-passphrase") ] * 4, passbolt_users, "reads the calling workspace's entry anew for each request"

    assert_match(/not on this voip.ms account/, run_tool(READ, { "number" => "9055550199" }, id: "not-on-account")[:error])
  end

  test "changing SMS forward keeps the full SMS form and shows old and new on the card and in the result" do
    forms = stub_settings(updated_did: did(sms_forward: OTHER))
    @agent.workspace.update!(approval_policy: "everything")
    args = { "sms_forward" => OTHER }
    assert_equal "waiting", receive(CHANGE, args)[:status]
    assert_empty forms
    card = fetch_preview
    assert_equal({ "sms_forward" => "9055550100 → #{OTHER}" }, card.details)
    assert_empty card.always_choices
    assert_private card.preview
    card.approve!(by: @person)

    assert_equal({ number: NUMBER, sms_forward: { before: "9055550100", after: OTHER } }, run_tool(CHANGE, args))
    assert_equal %w[ getDIDsInfo getDIDsInfo setSMS getDIDsInfo ], forms.pluck("method")
    assert_equal sms_form("sms_forward" => OTHER), forms.select { it["method"] == "setSMS" }.sole
  end

  test "changing voicemail email carries password and every other setting only in the multipart request" do
    addresses = "one@example.com,two@example.com"
    forms = stub_settings(updated_mailbox: mailbox(email: addresses))
    args = { "voicemail_email" => addresses }
    result = approve_and_run(args) do |card|
      assert_equal({ "voicemail_email" => "old-vm@example.com → #{addresses}" }, card.details)
      assert_private card.preview
    end
    assert_equal({ number: NUMBER, voicemail_email: { before: "old-vm@example.com", after: addresses } }, result)
    assert_private result
    assert_equal %w[ getDIDsInfo getDIDsInfo getVoicemails getDIDsInfo getDIDsInfo getVoicemails setVoicemail getVoicemails ], forms.pluck("method")
    assert_equal form("setVoicemail", mailbox(email: addresses).except(:unrelated).stringify_keys), forms.select { it["method"] == "setVoicemail" }.sole
    assert_requested(:post, /voip\.ms/, times: forms.size) { it.uri.query.nil? && it.headers["Content-Type"].start_with?("multipart/form-data;") }
  end

  test "empty SMS values disable the matching flags and a different re-read is reported" do
    forms = stub_settings(initial_did: did(sms_email: "old-sms@example.com", sms_email_enabled: "1"),
      updated_did: did(sms_forward: "", sms_forward_enabled: "0", sms_email: "still-on@example.com", sms_email_enabled: "1"))
    result = approve_and_run({ "sms_forward" => "", "sms_email" => "" })

    assert_equal sms_form("sms_forward" => "", "sms_forward_enable" => "0", "email_address" => "", "email_enabled" => "0"),
      forms.select { it["method"] == "setSMS" }.sole
    assert_equal({ before: "9055550100", after: "" }, result[:sms_forward])
    assert_equal({ before: "old-sms@example.com", after: "still-on@example.com" }, result[:sms_email])
    assert_match(/sms_email.*did not match/, result[:warning])
  end

  test "a combined change enables SMS email and clears voicemail email, verifying each write" do
    email = "new-sms@example.com"
    forms = stub_settings(updated_did: did(sms_email: email, sms_email_enabled: "1"), updated_mailbox: mailbox(email: ""))
    result = approve_and_run({ "sms_email" => email, "voicemail_email" => "" })

    assert_equal({ number: NUMBER, sms_email: { before: "", after: email }, voicemail_email: { before: "old-vm@example.com", after: "" } }, result)
    assert_equal %w[ getDIDsInfo getDIDsInfo getVoicemails getDIDsInfo getDIDsInfo getVoicemails setSMS getDIDsInfo setVoicemail getVoicemails ], forms.pluck("method")
    assert_equal sms_form("email_address" => email, "email_enabled" => "1"), forms.select { it["method"] == "setSMS" }.sole
    assert_equal "", forms.select { it["method"] == "setVoicemail" }.sole.fetch("email")
  end

  test "a record missing a field it must carry back, dialmode here, is refused before any write" do
    assert_refused_unsafe did.except(:dialmode), mailbox, { "sms_forward" => OTHER }, /dialmode/
  end

  test "an SMS change while SMPP is on is refused, since its password can't be read back" do
    assert_refused_unsafe did(smpp_enabled: "1"), mailbox, { "sms_email" => "new@example.com" }, /SMPP is enabled/
  end

  test "a voicemail email for a number with no mailbox is refused, along with the rest of a combined change" do
    assert_refused_unsafe did(voicemail: ""), mailbox, { "sms_forward" => OTHER, "voicemail_email" => "" }, /no voicemail mailbox/
  end

  test "a mailbox missing a field it must carry back is refused before any write" do
    assert_refused_unsafe did, mailbox.except(:password), { "voicemail_email" => "" }, /incomplete voicemail settings/
  end

  test "a voicemail email shared with another number's mailbox is refused, since changing it would change theirs" do
    forms = stub_settings(others: [ did(did: OTHER, routing: "voicemail:101", voicemail: "101") ])
    assert_equal "waiting", receive(CHANGE, { "voicemail_email" => "new@example.com" })[:status]
    card = fetch_preview
    assert_not card.approvable?
    assert_equal "This mailbox also takes voicemail for another number. Nothing was changed.", card.preview.fetch("error")
    assert_not_includes card.preview.fetch("error"), OTHER
    assert_empty forms.pluck("method").grep(/^set/)
  end

  test "a rejected write does not expose a password even if voip.ms echoes it in status" do
    forms = stub_settings(write_reply: { status: PIN, detail: API_KEY })
    result = approve_and_run({ "voicemail_email" => "" })
    assert_match(/voip.ms refused/, result.fetch(:error))
    assert_private result
    assert_equal "setVoicemail", forms.last.fetch("method")
  end

  test "changed settings require a fresh approval before writing" do
    forms = stub_settings
    args = { "sms_forward" => OTHER }
    receive(CHANGE, args)
    fetch_preview.approve!(by: @person)
    forms = stub_settings(initial_did: did(sms_forward: "9055550111"))

    receive(CHANGE, args)
    perform_enqueued_jobs(only: InvocationCallJob)
    card = invocation
    assert card.awaiting_person?
    assert_equal({ "sms_forward" => "9055550111 → #{OTHER}" }, card.details)
    assert_equal [ "getDIDsInfo" ], forms.pluck("method")
  end

  test "the model cannot change someone else's number or pass invalid changes" do
    forms = stub_settings
    assert_match(/Invalid arguments/, receive(CHANGE, { "number" => OTHER, "sms_forward" => NUMBER }, id: "other-number").dig(:result, :error))
    [ {}, { "sms_forward" => "123" }, { "sms_email" => "not an email" }, { "voicemail_email" => "one@example.com," },
      { "voicemail_email" => "x" * 250 + "@example.com" } ].each_with_index do |args, index|
      outcome = receive(CHANGE, args, id: "invalid-#{index}")
      assert outcome[:isError], outcome.to_json
    end
    assert_match(/Choose either/, receive(READ, { "number" => NUMBER, "list" => true }, id: "both").dig(:result, :error))
    assert_empty @conversation.invocations.awaiting_person
    assert_empty forms
  end

  test "own-number calls refuse clearly if the agent has no number or no account" do
    forms = stub_settings
    @agent.update!(phone_number: nil)
    assert_match(/no phone number/, run_tool(READ, {}, id: "no-number-read")[:error])
    assert_match(/no phone number/, run_tool(CHANGE, { "sms_forward" => OTHER }, id: "no-number-write")[:error])
    @agent.update!(phone_number: NUMBER)
    with_setting(:voipms, :password, nil) do
      assert_match(/no voip.ms account/, run_tool(READ, { "list" => true }, id: "no-account")[:error])
    end
    assert_empty forms
  end

  private
    def enable(name)
      assert @agent.switch_tool(name, true), @agent.errors.full_messages.to_sentence unless @agent.tool_names.include?(name)
    end

    def receive(name, args, id: "toolu_1")
      enable(name)
      @conversation.reload
      payload = invocation_payload(@conversation, tool: name, arguments: args, call_id: id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: id, tool: name,
        arguments: args, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_tool(name, args = {}, id: "toolu_1")
      receive(name, args, id:)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(name, args, id:).fetch(:result)
    end

    def invocation(id = "toolu_1") = @conversation.invocations.find_by!(call_id: id)

    def fetch_preview(id = "toolu_1")
      perform_enqueued_jobs(only: InvocationPreviewJob)
      invocation(id)
    end

    def approve_and_run(args)
      assert_equal "waiting", receive(CHANGE, args)[:status]
      card = fetch_preview
      yield card if block_given?
      card.approve!(by: @person)
      run_tool(CHANGE, args)
    end

    def assert_refused_unsafe(info, messages, args, reason)
      forms = stub_settings(initial_did: info, initial_mailbox: messages)
      assert_equal "waiting", receive(CHANGE, args)[:status]
      card = fetch_preview
      assert_not card.approvable?
      assert_match reason, card.preview.fetch("error")
      assert_private card.preview
      assert_empty forms.pluck("method").grep(/^set/)
    end

    def assert_private(result)
      [ PIN, API_KEY, "synthetic-pilot-key", "smpp-secret", "callback-secret", "webhook-secret", "smpp-user" ].each do |value|
        assert_not_includes result.to_json, value
      end
    end

    # others: the account's other numbers, which voip.ms lists only when asked for no one number.
    def stub_settings(initial_did: did, updated_did: initial_did, initial_mailbox: mailbox, updated_mailbox: initial_mailbox, write_reply: { status: "success" }, others: [])
      sms_written = voicemail_written = false
      stub_voipms do |fields|
        case fields.fetch("method")
        when "getDIDsInfo" then { status: "success", dids: [ sms_written ? updated_did : initial_did, *(others unless fields.key?("did")) ] }
        when "getVoicemails" then { status: "success", voicemails: [ voicemail_written ? updated_mailbox : initial_mailbox ] }
        when "setSMS" then sms_written = true; write_reply
        when "setVoicemail" then voicemail_written = true; write_reply
        end
      end
    end

    def did(**overrides)
      { did: NUMBER, routing: "voicemail:101", voicemail: "101", sms_available: "1", sms_enabled: "1", sms_email: "", sms_email_enabled: "0",
        sms_forward: "9055550100", sms_forward_enabled: "1", sms_url_callback: "https://example.com/callback-secret", sms_url_callback_enabled: "1",
        sms_url_callback_retry: "2", dialmode: "2", webhook: "https://example.com/webhook-secret", webhook_enabled: "1", smpp_enabled: "0",
        smpp_url: "example.com/smpp-secret", smpp_user: "smpp-user", smpp_pass: "smpp-secret" }.merge(overrides)
    end

    def mailbox(**overrides)
      { mailbox: "101", name: "Reception", password: PIN, skip_password: "0", email: "old-vm@example.com", attach_message: "1",
        email_attachment_format: "mp3", delete_message: "0", say_time: "1", timezone: "America/Toronto", say_callerid: "0",
        play_instructions: "1", language: "en", unrelated: "don't send this" }.merge(overrides)
    end

    def form(method, fields)
      { "api_username" => "texts@example.com", "api_password" => API_KEY, "method" => method }.merge(fields)
    end

    def sms_form(fields)
      form("setSMS", { "did" => NUMBER, "enable" => "1", "email_enabled" => "0", "email_address" => "", "sms_forward_enable" => "1",
        "sms_forward" => "9055550100", "url_callback_enable" => "1", "url_callback" => "https://example.com/callback-secret", "url_callback_retry" => "2",
        "dialmode" => "2", "webhook_enable" => "1", "webhook" => "https://example.com/webhook-secret", "smpp_enabled" => "0",
        "smpp_url" => "example.com/smpp-secret", "smpp_user" => "smpp-user" }.merge(fields))
    end
end
