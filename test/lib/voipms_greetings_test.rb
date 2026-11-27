require "test_helper"
require_relative "../test_helpers/voipms_test_helper"

class VoipmsGreetingsTest < ActiveSupport::TestCase
  include VoipmsTestHelper

  setup { install_voipms_settings }
  teardown { remove_voipms_settings }

  test "a recording lookup asks for one ID and returns only that recording's ID and name" do
    forms = stub_voipms(status: "success", recordings: [ { value: 8, description: "Other" }, { value: 7, description: "Weekends", file: "not returned" } ])
    assert_equal({ id: "7", name: "Weekends" }, greetings.recording(7))
    assert_equal [ "getRecordings", "7" ], forms.sole.values_at("method", "recording")
    assert_requested(:post, DurableAssistants::Voipms::URL.to_s, times: 1) { it.uri.query.nil? && it.headers["Content-Type"].start_with?("multipart/form-data;") }
  end

  test "the private recording read accepts a single ID and never routes writes" do
    forms = stub_voipms
    assert_not_respond_to greetings, :read_recording
    %w[ setRecording setVoicemail getVoicemails sendSMS arbitraryMethod ].each do |method|
      assert_raises(ArgumentError) { greetings.send(:read_recording, method, "7") }
    end
    [ nil, 0, "7&recording=8" ].each do |id|
      assert_raises(DurableAssistants::Voipms::Error) { greetings.send(:read_recording, "getRecordingFile", id) }
    end
    assert_empty forms

    greetings.send(:read_recording, "getRecordingFile", 7)
    assert_equal({ "method" => "getRecordingFile", "recording" => "7" }, forms.sole.except("api_username", "api_password"))
  end

  test "a missing or ambiguous recording cannot be mistaken for the requested one" do
    [ [], [ { value: 8, description: "Other" } ], [ { value: 7, description: "One" }, { value: 7, description: "Two" } ] ].each do |rows|
      stub_voipms(status: "success", recordings: rows)
      assert_raises(DurableAssistants::Voipms::Error) { greetings.recording("7") }
    end
  end

  test "a new recording encodes byte for byte what was approved, never passing an update ID" do
    forms = stub_voipms(status: "success", recording: 8)
    audio = "RIFF\x00\r\n\xffWAVE".b
    receipt = greetings.create_recording(name: "Weekends", bytes: audio, approved_sha256: Digest::SHA256.hexdigest(audio))
    assert_equal "8", receipt
    form = forms.sole
    assert_equal [ "setRecording", "Weekends" ], form.values_at("method", "name")
    assert_not form.key?("recording"), "an existing entry must never be overwritten"
    assert_equal audio, Base64.strict_decode64(form.fetch("file"))
  end

  test "missing or changed approved bytes never reach the provider" do
    forms = stub_voipms
    [ "changed".b, "".b, nil ].each do |audio|
      assert_raises(DurableAssistants::Voipms::Error) do
        greetings.create_recording(name: "Weekends", bytes: audio, approved_sha256: Digest::SHA256.hexdigest("approved"))
      end
    end
    assert_empty forms
  end

  test "a mailbox write carries all writable fields forward, changing only the unavailable recording" do
    existing = mailbox
    forms = mailbox_provider(existing)
    assert_equal "8", greetings.set_unavailable_recording(mailbox: "101", expected_recording_id: 7, recording_id: 8)
    assert_equal %w[ getVoicemails setVoicemail ], forms.pluck("method")
    assert_equal "101", forms.first.fetch("mailbox")
    sent = forms.last.except("method", "api_username", "api_password")
    assert_equal existing.except(:new, :urgent, :read_only).merge(unavailable_message_recording: 8).stringify_keys.transform_values(&:to_s), sent
  end

  test "missing, masked or changed settings never reach a write" do
    [ mailbox.except(:email), mailbox.except(:transcription_delay), mailbox.merge(password: "****"),
      mailbox.merge(transcription_locale: "[redacted]"), mailbox.merge(unavailable_message_recording: 42),
      mailbox.merge(unavailable_message_recording: nil), mailbox.merge(mailbox: 102) ].each do |existing|
      forms = mailbox_provider(existing)
      error = assert_raises(DurableAssistants::Voipms::Error) do
        greetings.set_unavailable_recording(mailbox: "101", expected_recording_id: 7, recording_id: 8)
      end
      assert_equal [ "getVoicemails" ], forms.pluck("method")
      assert_no_match(/synthetic-api-password|1234|weekends@example\.com/i, error.message)
    end
  end

  test "an empty address is preserved and a greeting can replace the zero recording" do
    forms = mailbox_provider(mailbox.merge(email: "", unavailable_message_recording: 0))
    assert_equal "8", greetings.set_unavailable_recording(mailbox: 101, expected_recording_id: "0", recording_id: "8")
    assert_equal "", forms.last.fetch("email")
    assert_equal "8", forms.last.fetch("unavailable_message_recording")
  end

  test "a lost write response does not retry or disclose the body" do
    stub = stub_request(:post, DurableAssistants::Voipms::URL.to_s).with { voipms_form(it)["method"] == "setRecording" }.to_raise(Net::ReadTimeout)
    audio = "approved recording bytes".b
    error = assert_raises(DurableAssistants::Voipms::Error) do
      greetings.create_recording(name: "Weekends", bytes: audio, approved_sha256: Digest::SHA256.hexdigest(audio))
    end
    assert_nil error.cause
    assert_no_match(/approved recording bytes|synthetic-api-password/, error.message)
    assert_requested stub, times: 1
  end

  test "a greeting switch times out on the mailbox write, reports it safely, and does not retry" do
    stub_request(:post, DurableAssistants::Voipms::URL.to_s).with { voipms_form(it)["method"] == "getVoicemails" }
      .to_return(body: { status: "success", voicemails: [ mailbox ] }.to_json)
    write = stub_request(:post, DurableAssistants::Voipms::URL.to_s).with do |request|
      voipms_form(request).values_at("method", "mailbox", "unavailable_message_recording") == %w[ setVoicemail 101 8 ]
    end.to_raise(Net::ReadTimeout.new("private mailbox password 1234 and weekends@example.com"))

    error = assert_raises(DurableAssistants::Voipms::Error) do
      greetings.set_unavailable_recording(mailbox: 101, expected_recording_id: 7, recording_id: 8)
    end

    assert_match(/timed out waiting for a response/i, error.message)
    assert_no_match(/1234|weekends@example.com|synthetic-api-password/, error.full_message)
    assert_nil error.cause
    assert_requested write, times: 1
    assert_requested :post, DurableAssistants::Voipms::URL.to_s, times: 2
  end

  private
    def greetings = DurableAssistants::Voipms.greetings(account: nil)

    def mailbox_provider(existing)
      stub_voipms do |form|
        form["method"] == "getVoicemails" ? { status: "success", voicemails: [ existing ] } : { status: "success" }
      end
    end

    def mailbox
      { mailbox: 101, name: "Weekends", password: 1234, skip_password: 0, email: "weekends@example.com",
        attach_message: "yes", delete_message: "no", say_time: "yes", timezone: "America/Chicago",
        say_callerid: "no", play_instructions: "su", language: "en", email_attachment_format: "wav49",
        transcription: "yes", transcription_locale: "en-US", transcription_redaction: "yes", transcription_summary: "no",
        transcription_sentiment: "no", transcription_format: "text", transcription_delay: 5,
        unavailable_message_recording: 7, new: 3, urgent: 0, read_only: "not sent" }
    end
end
