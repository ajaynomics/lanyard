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

  test "anything but success is an error, with voip.ms's own word for it" do
    stub_voipms(status: "limit_reached")
    error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
    assert_equal "voip.ms refused the text: limit_reached", error.message

    stub_request(:post, /voip\.ms/).to_return(status: 503, body: { status: "" }.to_json)
    error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
    assert_equal "voip.ms refused the text: HTTP 503", error.message

    stub_request(:post, /voip\.ms/).to_return(status: 500, body: "<soap:Fault>Bad Request for synthetic-api-password</soap:Fault>")
    error = assert_raises(DurableAssistants::Voipms::Error) { DurableAssistants::Voipms.send_text(from: "6475550123", to: "4165550199", body: "Hi") }
    assert_equal "voip.ms answered HTTP 500 (not JSON)", error.message, "nothing of the body"
  end

  # The API password is the whole account's: it could read every message, or
  # move the account's numbers. So the app asks for two things, and nothing
  # else holds the password or the address.
  test "it asks voip.ms only to send, and is the only code that can ask" do
    assert_equal %w[ sendSMS sendMMS ], DurableAssistants::Voipms::METHODS
    stub_voipms
    %w[ getSMS getDIDsInfo setDIDRouting cancelDID ].each do |method|
      assert_raises(ArgumentError) { DurableAssistants::Voipms.send(:request, method, did: "6475550123") }
    end
    assert_not_requested :any, /voip\.ms/
    assert_raises(NoMethodError) { DurableAssistants::Voipms.request("sendSMS") }

    callers = Dir[Rails.root.join("{app,lib,config,agent}/**/*.{rb,mjs,js,yml,erb}")].reject { it.include?("node_modules") }
      .select { File.read(it).match?(/voip\.ms\/api|api_password|:voipms, :password/) }
    assert_equal [ "config/voipms.yml", "lib/durable_assistants/voipms.rb" ], callers.map { it.delete_prefix("#{Rails.root}/") }.sort
  end
end
