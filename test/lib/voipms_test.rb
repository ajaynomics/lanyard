require "test_helper"
require_relative "../test_helpers/voipms_test_helper"

class VoipmsTest < ActiveSupport::TestCase
  include VoipmsTestHelper

  setup { install_voipms_settings }
  teardown { remove_voipms_settings }

  test "a short text goes as SMS, by a multipart POST, with the password in the body and never the URL" do
    forms = stub_voipms
    assert_equal 23434, DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "On my way.")

    assert_requested(:post, "https://voip.ms/api/v1/rest.php", times: 1) { it.uri.query.nil? && it.headers["Content-Type"].start_with?("multipart/form-data; boundary=") }
    assert_equal({ "api_username" => "texts@example.com", "api_password" => "synthetic-api-password", "method" => "sendSMS",
                   "did" => "6475550123", "dst" => "4165550199", "message" => "On my way." }, forms.sole)
  end

  test "past 160 characters it goes as one MMS" do
    forms = stub_voipms(status: "success", mms: 991)
    assert_equal 991, DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "a" * 161)
    assert_equal "sendMMS", forms.sole["method"]
    assert_equal "a" * 161, forms.sole["message"]
  end

  test "a recognised JSON refusal exposes only its status and the HTTP code" do
    stub_voipms(status: "invalid_credentials", reason: "synthetic-api-password")
    error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
    assert_equal "voip.ms refused the request (HTTP 200; invalid_credentials)", error.message
  end

  test "a status outside the pattern is not echoed, even if the client lists it" do
    [ "synthetic-api-password", "e911_disabled", "rtp_timeout_greater_than_rtp_hold_timeout", 123 ].each do |status|
      stub_voipms(status:)
      error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
      assert_equal "voip.ms refused the request (HTTP 200; unrecognised status)", error.message
    end
  end

  test "a lowercase secret-shaped status not in the list is not echoed" do
    stub_voipms(status: "synthetic_api_password")
    error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
    assert_equal "voip.ms refused the request (HTTP 200; unrecognised status)", error.message
  end

  test "an unreadable HTTP 200 is unconfirmed after one readback" do
    write = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }
      .to_return(body: "<soap:Fault>private_provider_payload</soap:Fault>")
    read = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }.to_return(body: '{"status":"no_sms"}')

    error = assert_raises(DurableAssistants::Voipms::Unconfirmed) do
      DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "private_text_payload")
    end
    assert_equal "Delivery is unknown. Send: unreadable response (HTTP 200; unrecognised status). Readback: no matching text was listed.", error.message
    assert_nil error.cause
    assert_no_match(/private_(provider|text)_payload|synthetic-api-password|4165550199|not sent/i, error.full_message)
    assert_requested write, times: 1
    assert_requested read, times: 1
  end

  # A live case: voip.ms took 17 to 19 seconds to answer a send, past the
  # old 15, and the texts went. Connecting still gives up at 15.
  test "a send waits 45 seconds for voip.ms's answer, and 15 to connect" do
    stub_voipms
    Net::HTTP.singleton_class.prepend(RecordsTimeouts)
    opened = Thread.current[:net_http_timeouts] = []
    DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "On my way.")
    assert_equal [ { open_timeout: 15, read_timeout: 45 } ], opened
  ensure
    Thread.current[:net_http_timeouts] = nil
  end

  test "a send that times out waiting for the answer is looked up, and found there it was sent, with its id" do
    sent_after_timeout("sendSMS")
    looked_up = answer_lookup("getSMS", [ sms(id: 23999, message: "On my way.") ])

    assert_equal 23999, DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "On my way.")
    assert_equal [ "6475550123", "4165550199", "0" ], looked_up.sole.values_at("did", "contact", "type"), "only the agent's own number, to that recipient, sent"
  end

  test "an MMS that times out is looked up among MMS" do
    sent_after_timeout("sendMMS")
    answer_lookup("getMMS", [ sms(id: 777, message: "a" * 161) ])
    assert_equal 777, DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "a" * 161)
  end

  test "not found, or found only from another number, to another, with other words or from before the send, it is unknown, never failed" do
    sent_after_timeout("sendSMS")
    answer_lookup("getSMS", [ sms(id: 1, message: "On my way.", did: "9055550100"), sms(id: 2, message: "On my way.", contact: "9055550100"),
      sms(id: 3, message: "On my way!"), sms(id: 4, message: "On my way.", date: 1.hour.ago), sms(id: 5, message: "On my way.", type: "1") ])

    error = assert_raises(DurableAssistants::Voipms::Unconfirmed) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "On my way.") }
    assert_not_kind_of DurableAssistants::Voipms::Error, error, "not a refusal: it may have gone"
  end

  {
    "refused" => [ { status: "invalid_credentials", detail: "private_lookup_payload" }.to_json, "refused (HTTP 200; invalid_credentials)" ],
    "timed out" => [ Net::OpenTimeout.new("private_lookup_payload"), "timed out opening the connection" ],
    "empty" => [ { status: "no_sms" }.to_json, "no matching text was listed" ]
  }.each do |scenario, (lookup, reason)|
    test "an uncertain send keeps the safe reasons when readback is #{scenario}, without resending" do
      write = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }.to_raise(Net::ReadTimeout.new("private_send_payload"))
      read = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }
      lookup.is_a?(Exception) ? read.to_raise(lookup) : read.to_return(body: lookup)

      error = assert_raises(DurableAssistants::Voipms::Unconfirmed) do
        DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "private_send_payload")
      end
      assert_nil error.cause
      assert_no_match(/private_(send|lookup)_payload|6475550123|4165550199|not sent/i, error.full_message)
      assert_requested write, times: 1
      assert_requested read, times: 1
      assert_equal "Delivery is unknown. Send: timed out waiting for a response. Readback: #{reason}.", error.message
    end
  end

  # Asked again later, until it is known (Dispatch#check): nothing listed and
  # a list that can't be had must be told apart, as only the first says it
  # never went.
  test "a later lookup tells nothing listed from a list it couldn't have" do
    answer_lookup("getMMS", [ sms(id: 777, message: "a" * 161) ])
    assert_equal 777, DurableAssistants::Voipms.sent_id(from: "6475550123", to: "4165550199", body: "a" * 161, since: 1.minute.ago)

    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }.to_return(body: { status: "no_sms" }.to_json)
    assert_nil DurableAssistants::Voipms.sent_id(from: "6475550123", to: "4165550199", body: "Hi", since: 1.minute.ago)

    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }.to_raise(Net::ReadTimeout)
    assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.sent_id(from: "6475550123", to: "4165550199", body: "Hi", since: 1.minute.ago) }
    stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }.to_return(body: { status: "invalid_credentials" }.to_json)
    assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.sent_id(from: "6475550123", to: "4165550199", body: "Hi", since: 1.minute.ago) }
  end

  test "never connecting is plainly not sent, and nothing is looked up" do
    stub_request(:post, /voip\.ms/).to_raise(Net::OpenTimeout)
    error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
    assert_equal "voip.ms timed out opening the connection; the request was not sent.", error.message
    assert_equal :connect_timeout, error.reason
    assert_not error.outcome_unknown?
    assert_requested :post, /voip\.ms/, times: 1
  end

  test "connection refusal before Net::HTTP yields sends nothing and does not read back" do
    Net::HTTP.singleton_class.prepend(RecordsTimeouts)
    starts = Thread.current[:net_http_timeouts] = []
    Thread.current[:voip_connection_failure] = Errno::ECONNREFUSED.new("private_connection_payload")

    error = assert_raises(DurableAssistants::Voipms::Error) do
      DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi")
    end
    assert_equal :connection_failed, error.reason
    assert_equal Errno::ECONNREFUSED, error.source_class
    assert_not error.outcome_unknown?
    assert_nil error.cause
    assert_no_match(/private_connection_payload/, error.full_message)
    assert_equal [ { open_timeout: 15, read_timeout: 45 } ], starts
    assert_not_requested :any, /voip\.ms/
    assert_equal "Could not reach voip.ms (connection was refused; unrecognised status); the request was not sent.", error.message
    assert_equal "connection was refused (unrecognised status)", error.diagnostic
  ensure
    Thread.current[:net_http_timeouts] = nil
    Thread.current[:voip_connection_failure] = nil
  end

  test "an unreadable transport response after a send checks the list, never resends" do
    write = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "sendSMS" }
      .to_raise(Net::HTTPBadResponse.new("private text payload"))
    read = stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == "getSMS" }
      .to_return(body: { status: "no_sms" }.to_json)
    error = assert_raises(DurableAssistants::Voipms::Unconfirmed) do
      DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "private text payload")
    end
    assert_nil error.cause
    assert_no_match(/private text payload/, error.full_message)
    assert_requested write, times: 1
    assert_requested read, times: 1
  end

  # What each Net::HTTP.start was asked to wait, while a test listens.
  module RecordsTimeouts
    def start(*arguments, **options, &block)
      Thread.current[:net_http_timeouts]&.push(options.slice(:open_timeout, :read_timeout))
      failure = Thread.current[:voip_connection_failure]
      raise failure if failure
      super
    end
  end

  private
    # voip.ms took the send but its answer never came in time.
    def sent_after_timeout(method)
      stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == method }.to_raise(Net::ReadTimeout)
    end

    def answer_lookup(method, messages)
      forms = []
      stub_request(:post, /voip\.ms/).with { voipms_form(it)["method"] == method }.to_return do |request|
        forms << voipms_form(request)
        { body: { status: "success", sms: messages }.to_json, headers: { "Content-Type" => "application/json" } }
      end
      forms
    end

    # One message as getSMS lists it, its date in UTC as asked (timezone 0).
    def sms(id:, message:, did: "6475550123", contact: "4165550199", type: "0", date: Time.current)
      { id: id.to_s, date: date.utc.strftime("%Y-%m-%d %H:%M:%S"), type: type, did: did, contact: contact, message: message }
    end

  test "the private transport accepts the exact recording file lookup" do
    forms = stub_voipms
    DurableAssistants::Voipms.send(:request, "getRecordingFile", account: nil, recording: "7")
    assert_equal({ "method" => "getRecordingFile", "recording" => "7" }, forms.sole.except("api_username", "api_password"))
    assert_requested(:post, DurableAssistants::Voipms::URL.to_s, times: 1) { it.uri.query.nil? }
  end

  # The API password is the whole account's: no other code may hold it,
  # and only the methods the app needs are reachable.
  test "only the allowed operations can reach voip.ms, and this is the only code that can ask" do
    assert_equal %w[ sendSMS sendMMS getSMS getMMS getDIDsInfo setSMS getVoicemails setVoicemail getRecordings setRecording getRecordingFile ], DurableAssistants::Voipms::METHODS
    stub_voipms
    %w[ setDIDInfo getVoicemailMessages setDIDRouting cancelDID ].each do |method|
      assert_raises(ArgumentError) { DurableAssistants::Voipms.send(:request, method, account: nil, did: "6475550123") }
    end
    assert_not_requested :any, /voip\.ms/
    assert_raises(NoMethodError) { DurableAssistants::Voipms.request("sendSMS") }

    callers = Dir[Rails.root.join("{app,lib,config,agent}/**/*.{rb,mjs,js,yml,erb}")].reject { it.include?("node_modules") }
      .select { File.read(it).match?(/voip\.ms\/api|api_password|:voipms, :password/) }
    assert_equal [ "config/voipms.yml", "lib/durable_assistants/voipms.rb" ], callers.map { it.delete_prefix("#{Rails.root}/") }.sort
  end
end
