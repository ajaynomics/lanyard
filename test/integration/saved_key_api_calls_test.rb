require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# An HTTPS call with a key from the vault (docs/passwords.md). The vault entry
# names the one host it may reach; the key goes from the vault into that one
# request as a bearer token, and never into the model's result, the ledger or
# the logs. The fake `passbolt` command and the API are stand-ins at their
# boundaries; the tool, the ledger and the request run for real.
class SavedKeyApiCallsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include PassboltTestHelper

  KEY = PassboltTestHelper::PASSWORD
  CALL = { "name" => "Cal.com API key", "method" => "POST", "path" => "/v2/bookings",
    "query" => { "status" => "upcoming" }, "body" => { "start" => "2026-11-20T15:00:00Z" },
    "headers" => { "cal-api-version" => "2024-08-13" } }.freeze

  setup do
    install_sidecar_settings
    install_fake_passbolt(name: "Cal.com API key", uri: "https://api.cal.example")
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(tool_names: @agent.tool_names + [ "call_api_with_saved_key" ])
    @conversation = create_conversation(@agent)
  end
  teardown do
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "it is picked, never given: an agent has it only once a person switches it on" do
    other = create_user(name: "Bo").agents.sole
    assert_nil create_conversation(other).tool("call_api_with_saved_key")
    assert @conversation.tool("call_api_with_saved_key")
  end

  test "approved, it sends one request to the entry's host with the key, and the model, ledger and log never see the key" do
    api = stub_request(:post, "https://api.cal.example/v2/bookings?status=upcoming")
      .with(headers: { "Authorization" => "Bearer #{KEY}", "cal-api-version" => "2024-08-13", "Content-Type" => "application/json" },
        body: { start: "2026-11-20T15:00:00Z" }.to_json)
      .to_return(status: 201, body: { id: 42, echoed: KEY }.to_json)

    log = capture_log do
      assert_equal "waiting", invoke(CALL)["status"]
      assert_empty passbolt_calls, "nothing is read from the vault before the person answers"
      @conversation.invocations.sole.approve!(by: @alice)
      invoke(CALL)
      perform_enqueued_jobs(only: InvocationCallJob)
      done = invoke(CALL)
      assert_equal "done", done["status"]
      assert_equal 201, done["result"]["status"]
      assert_equal({ "id" => 42, "echoed" => "[the saved key]" }, JSON.parse(done["result"]["body"]))
      assert_not_includes done.to_json, KEY
    end
    assert_requested api, times: 1
    assert_not_includes @conversation.invocations.sole.reload.attributes.to_json, KEY
    assert_match "InvocationCallJob", log, "the log was read"
    assert_not_includes log, KEY
  end

  test "an entry the agent can't read is refused, and nothing is sent" do
    result = approved({ **CALL, "name" => "Someone else's key" })
    assert result["isError"]
    assert_match "Nothing called Someone else's key is shared", result["result"].to_s
    assert_not_requested :any, /cal\.example/
  end

  test "a sign-in the agent's own mail account uses is never sent as a key, and nothing is asked" do
    @agent.create_mail_account!(address: "desk@cal.example", smtp_host: "api.cal.example", vault_entry: "cal.com API key")
    sent = stub_request(:any, /cal\.example/)
    result = invoke(CALL)
    assert_equal "done", result["status"], "refused before anyone is asked"
    assert result["isError"]
    assert_match "belongs to your own mail or calendar account, so it can't be used as a key", result.to_json
    assert_not_requested sent
  end

  test "an entry saved with an http address reaches no host" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Cal.com API key", uri: "http://api.cal.example")
    result = approved(CALL)
    assert result["isError"]
    assert_match "no https address", result["result"].to_s
    assert_not_requested :any, /cal\.example/
  end

  test "no path, header or query reaches a host other than the entry's, or replaces its key" do
    elsewhere = stub_request(:any, %r{\Ahttps?://evil\.example})
    [ { "path" => "//evil.example/v2" }, { "path" => "https://evil.example/v2" }, { "path" => "v2/bookings" },
      { "headers" => { "Authorization" => "Bearer theirs" } }, { "headers" => { "cal-api-version" => "x\r\nX-Evil: 1" } }, { "headers" => { "Host" => "evil.example" } } ].each_with_index do |change, index|
      result = approved({ **CALL, **change }, call_id: "toolu_#{index}")
      assert result["isError"], change.inspect
    end
    assert_not_requested elsewhere

    broken = approved({ **CALL, "headers" => { "cal-api-version" => "x\nX-Evil: 1" } }, call_id: "toolu_break")
    assert_match "cal-api-version's value can't contain a line break", broken["result"].to_s, "a reason, not a crash"
    assert_not_requested :any, /cal\.example/

    on_host = stub_request(:get, "https://api.cal.example/@evil.example/x").to_return(body: "{}")
    approved({ **CALL.except("query", "body"), "method" => "GET", "path" => "/@evil.example/x" }, call_id: "toolu_at")
    assert_requested on_host, times: 1
    assert_not_requested elsewhere
  end

  private
    def invoke(arguments, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "call_api_with_saved_key", arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    def approved(arguments, call_id: "toolu_1")
      invoke(arguments, call_id:)
      @conversation.invocations.find_by!(call_id:).approve!(by: @alice)
      invoke(arguments, call_id:)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(arguments, call_id:)
    end

    def capture_log
      output = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::BroadcastLogger.new(previous, ActiveSupport::Logger.new(output))
      ActiveJob::Base.logger = ActionController::Base.logger = Rails.logger
      yield
      output.string
    ensure
      Rails.logger = ActiveJob::Base.logger = ActionController::Base.logger = previous
    end
end
