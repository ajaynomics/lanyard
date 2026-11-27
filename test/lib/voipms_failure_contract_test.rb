require "test_helper"
require_relative "../test_helpers/voipms_test_helper"

class VoipmsFailureContractTest < ActiveSupport::TestCase
  include VoipmsTestHelper

  VOIP = DurableAssistants::Voipms
  PRIVATE = "private_provider_payload"
  TRANSPORT_CASES = {
    Net::OpenTimeout => [ :connect_timeout, "timed out opening the connection" ],
    Net::ReadTimeout => [ :read_timeout, "timed out waiting for a response" ],
    Net::WriteTimeout => [ :write_timeout, "timed out sending the request" ],
    Timeout::Error => [ :request_timeout, "request timed out" ],
    Errno::ETIMEDOUT => [ :request_timeout, "request timed out" ],
    EOFError => [ :uncertain_transport, "connection closed early" ],
    IOError => [ :uncertain_transport, "network I/O failed" ],
    SocketError => [ :uncertain_transport, "address or DNS lookup failed" ],
    Errno::ECONNRESET => [ :uncertain_transport, "connection was reset" ],
    Errno::EPIPE => [ :uncertain_transport, "connection pipe broke" ],
    Errno::ECONNREFUSED => [ :uncertain_transport, "connection was refused" ],
    OpenSSL::SSL::SSLError => [ :uncertain_transport, "TLS failed" ],
    Net::ProtocolError => [ :uncertain_transport, "HTTP protocol error" ],
    Net::HTTPBadResponse => [ :uncertain_transport, "invalid HTTP response" ],
    Net::HTTPHeaderSyntaxError => [ :uncertain_transport, "invalid HTTP headers" ],
    Zlib::DataError => [ :uncertain_transport, "response decompression failed" ],
    Errno::EINVAL => [ :uncertain_transport, "unrecognised status" ]
  }.freeze

  setup { install_voipms_settings }
  teardown { remove_voipms_settings }

  VOIP::METHODS.each do |method|
    test "#{method} names the status it got, but no other field and nothing like a credential" do
      text_send = %w[ sendSMS sendMMS ].include?(method)
      [ [ 403, "invalid_credentials", "invalid_credentials" ], [ 200, "missing_greeting", "missing_greeting" ],
        [ 200, "texts", "unrecognised status" ], [ 200, "api", "unrecognised status" ],
        [ 502, [], "unrecognised status" ], [ 500, nil, "unrecognised status" ] ].each do |code, status, safe|
        stub_method(method).to_return(status: code, body: { status: status, reason: PRIVATE }.to_json)
        failure = provider_error(method)
        server_failure = text_send && code >= 500
        assert_equal(server_failure ? :server_error : :refused, failure.reason)
        assert_equal code, failure.http_code
        assert_equal(server_failure ? "unrecognised status" : safe, failure.status)
        expected = if server_failure
          "voip.ms returned HTTP #{code}. The send failed. Check voip.ms's message log before any manual resend."
        else
          "voip.ms refused the request (HTTP #{code}; #{safe})"
        end
        assert_equal expected, failure.message
        assert_not failure.outcome_unknown?
      end

      [ "<soap:Fault>#{PRIVATE}</soap:Fault>", "[]", "null" ].each do |body|
        stub_method(method).to_return(status: 502, body: body)
        failure = provider_error(method)
        assert_equal(text_send ? :server_error : :unreadable_response, failure.reason)
        assert_equal "unrecognised status", failure.status
        assert_equal 502, failure.http_code
        assert_not failure.outcome_unknown?
      end
    end

    test "#{method} normalizes transport errors and keeps only the source type" do
      TRANSPORT_CASES.each do |source, (reason, words)|
        call = stub_method(method).to_raise(source.new(PRIVATE))
        failure = provider_error(method)
        assert_equal reason, failure.reason, source.name
        assert_equal source, failure.source_class
        assert_nil failure.http_code
        assert_equal "unrecognised status", failure.status
        assert_equal (reason != :connect_timeout), failure.outcome_unknown?
        assert_includes failure.message, reason == :request_timeout ? "request to voip.ms timed out" : words, source.name
        assert_includes failure.diagnostic, words, source.name
        assert_no_match(/#{PRIVATE}|9876543210|synthetic-api-password|texts@example.com/, failure.diagnostic)
        assert_requested call, times: 1
        WebMock::RequestRegistry.instance.reset!
      end
    end
  end

  private
    def stub_method(method)
      stub_request(:post, VOIP::URL.to_s).with { voipms_form(it)["method"] == method && it.uri.query.nil? }
    end

    def provider_error(method)
      failure = assert_raises(VOIP::Error) { VOIP.send(:request, method, account: nil, mailbox: "9876543210") }
      assert_nil failure.cause
      assert_no_match(/#{PRIVATE}|9876543210|synthetic-api-password|texts@example.com/, failure.full_message)
      failure
    end
end
