require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

# A Clio Manage connector (McpServer::Clio): its OAuth app's client ID and
# secret are read from a vault entry each time they are needed, its sign-in
# is kept on the connector, encrypted, and its reads run at once while the one
# write, a calendar entry, asks a person every time.
class McpServer::ClioTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  API = "https://app.clio.com/api/v4".freeze
  TOKEN_URL = "https://app.clio.com/oauth/token".freeze
  ACCESS, REFRESH, FRESH = "clio-access-5521", "clio-refresh-8830", "clio-access-6402"

  setup do
    install_fake_passbolt(name: "Clio app", uri: "https://app.clio.com")
    @agent = create_user.agents.sole
    @connector = @agent.user.mcp_servers.create!(name: "clio", **McpServer.gallery_attributes(:clio), vault_entry: "Clio app",
      oauth_tokens: { "access_token" => ACCESS, "refresh_token" => REFRESH, "expires_at" => 1.hour.from_now.to_i })
    make_core(@agent, @connector)
    @connector.refresh
  end

  teardown { remove_fake_passbolt }

  test "it lists its reads and one write; reads run at once marked as data, and the write asks every time, even approving everything" do
    assert_equal %w[ search_matters get_matter search_contacts get_contact list_custom_fields search_documents get_document
      list_calendars list_calendar_entries create_calendar_entry ], @connector.reload.tools.pluck("name")
    tools = @agent.reload.conversation.tools.grep(Tool::Mcp).index_by { it.listing["name"] }
    reads = tools.except("create_calendar_entry").values
    assert reads.all? { it.asks.nil? }, "reads run at once"
    assert tools.values_at("search_matters", "get_matter", "search_contacts", "get_document", "list_calendar_entries").all? { it.description.include?(McpServer::Google::DATA) }
    assert_equal :approval, tools["create_calendar_entry"].asks

    conversation = @agent.conversation
    with_setting(:app, :approve_everything, true) do
      create = receive(conversation, "mcp__clio__create_calendar_entry",
        { "calendar_id" => 7, "summary" => "Filing deadline", "start_at" => "2026-12-01T09:00:00Z", "end_at" => "2026-12-01T10:00:00Z" }, "c1")
      assert create.awaiting_person?, "a new calendar entry shows its approval card where the install approves everything"
      assert_empty create.always_choices, "and offers no Always"
      assert_not receive(conversation, "mcp__clio__search_matters", { "query" => "lease" }, "c2").awaiting_person?
    end
  end

  test "searching matters asks Clio for named fields, a page at a time, and hands back the next page's token" do
    matters = stub_request(:get, "#{API}/matters.json")
      .with(query: hash_including("query" => "lease", "status" => "open", "limit" => "2", "page_token" => "p1",
        "fields" => McpServer::Clio::FIELDS[:matter], "order" => "id(asc)"), headers: { "Authorization" => "Bearer #{ACCESS}" })
      .to_return(json(data: [ { id: 11, display_number: "00011-Lease", description: "Lease review", status: "Open" } ],
        meta: { paging: { next: "#{API}/matters.json?fields=id&limit=2&page_token=p2" }, records: 3 }))

    result = call("search_matters", "query" => "lease", "status" => "open", "limit" => 2, "page_token" => "p1")

    assert_requested matters
    assert_equal({ "matters" => [ { "id" => 11, "display_number" => "00011-Lease", "description" => "Lease review", "status" => "Open" } ],
      "next_page_token" => "p2" }, result["structuredContent"])
  end

  test "one matter, contact, document and the calendars come back with their fields; a document is described, never downloaded" do
    stub_request(:get, "#{API}/matters/11.json").with(query: { fields: McpServer::Clio::FIELDS[:matter_detail] }).to_return(json(data: { id: 11 }))
    stub_request(:get, "#{API}/contacts/5.json").with(query: { fields: McpServer::Clio::FIELDS[:contact_detail] }).to_return(json(data: { id: 5 }))
    stub_request(:get, "#{API}/documents/9.json").with(query: { fields: McpServer::Clio::FIELDS[:document] }).to_return(json(data: { id: 9, name: "Lease.pdf", size: 1024 }))
    stub_request(:get, "#{API}/calendars.json").with(query: hash_including("fields" => McpServer::Clio::FIELDS[:calendar])).to_return(json(data: [ { id: 7, name: "Firm" } ]))
    entries = stub_request(:get, "#{API}/calendar_entries.json")
      .with(query: hash_including("from" => "2026-12-01T00:00:00Z", "to" => "2026-12-31T00:00:00Z", "calendar_id" => "7", "expanded" => "true"))
      .to_return(json(data: []))

    assert_equal({ "matter" => { "id" => 11 } }, call("get_matter", "matter_id" => 11)["structuredContent"])
    assert_equal({ "contact" => { "id" => 5 } }, call("get_contact", "contact_id" => 5)["structuredContent"])
    assert_equal({ "document" => { "id" => 9, "name" => "Lease.pdf", "size" => 1024 } }, call("get_document", "document_id" => 9)["structuredContent"])
    assert_equal({ "calendars" => [ { "id" => 7, "name" => "Firm" } ] }, call("list_calendars")["structuredContent"])
    call("list_calendar_entries", "from" => "2026-12-01T00:00:00Z", "to" => "2026-12-31T00:00:00Z", "calendar_id" => 7)
    assert_requested entries
    assert_not_requested :get, %r{/documents/9/download}
  end

  test "a calendar entry is made on the calendar given, with the matter when one is named" do
    created = stub_request(:post, "#{API}/calendar_entries.json").with(query: hash_including("fields"),
      body: { data: { summary: "Filing deadline", start_at: "2026-12-01T09:00:00Z", end_at: "2026-12-01T10:00:00Z", all_day: false,
        calendar_owner: { id: 7 }, matter: { id: 11 } } }.to_json)
      .to_return(json(data: { id: 30, summary: "Filing deadline" }).merge(status: 201))

    result = call("create_calendar_entry", "calendar_id" => 7, "summary" => "Filing deadline", "start_at" => "2026-12-01T09:00:00Z",
      "end_at" => "2026-12-01T10:00:00Z", "all_day" => false, "matter_id" => 11)

    assert_requested created
    assert_equal({ "calendar_entry" => { "id" => 30, "summary" => "Filing deadline" } }, result["structuredContent"])
  end

  test "an expiring token is renewed with the app's client from the vault, and the refresh token kept" do
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 30.seconds.from_now.to_i))
    renewed = stub_request(:post, TOKEN_URL)
      .with(body: { grant_type: "refresh_token", refresh_token: REFRESH, client_id: "maya", client_secret: PASSWORD })
      .to_return(json(access_token: FRESH, token_type: "bearer", expires_in: 2_592_000))
    stub_request(:get, "#{API}/calendars.json").with(query: hash_including({}), headers: { "Authorization" => "Bearer #{FRESH}" }).to_return(json(data: []))

    call("list_calendars")

    assert_requested renewed
    tokens = @connector.reload.oauth_tokens
    assert_equal [ FRESH, REFRESH ], tokens.values_at("access_token", "refresh_token")
    assert_operator tokens["expires_at"], :>, 29.days.from_now.to_i
    assert_match(/ARGS get resource --id 7f0c/, passbolt_calls)
  end

  test "a token Clio turns away is renewed once and the call made again; a refresh Clio refuses asks the person to sign in" do
    stub_request(:get, "#{API}/calendars.json").with(query: hash_including({}), headers: { "Authorization" => "Bearer #{ACCESS}" }).to_return(status: 401)
    stub_request(:get, "#{API}/calendars.json").with(query: hash_including({}), headers: { "Authorization" => "Bearer #{FRESH}" }).to_return(json(data: []))
    stub_request(:post, TOKEN_URL).to_return(json(access_token: FRESH, expires_in: 3600))

    assert_equal({ "calendars" => [] }, call("list_calendars")["structuredContent"])

    @connector.reload.update!(oauth_tokens: @connector.oauth_tokens.merge("access_token" => ACCESS))
    stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    assert_raises(McpServer::SignInNeeded) { call("list_calendars") }
    assert @connector.reload.needs_sign_in?
    assert_nil @connector.oauth_tokens
    assert_equal "needs_sign_in", @connector.status
  end

  test "neither the client secret nor a token reaches a tool's answer, an error or the log" do
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 30.seconds.from_now.to_i))
    stub_request(:post, TOKEN_URL).to_return(json(access_token: FRESH, refresh_token: "clio-refresh-9944", expires_in: 3600))
    stub_request(:get, "#{API}/contacts.json").with(query: hash_including({})).to_return(json(data: [ { id: 5, name: "Avery Example" } ]))
    stub_request(:get, "#{API}/custom_fields.json").with(query: hash_including({})).to_return(status: 403, body: { error: { message: "Forbidden" } }.to_json)

    log = StringIO.new
    Rails.logger.broadcast_to(capture = ActiveSupport::Logger.new(log))
    answers = [ call("search_contacts", "query" => "Avery"), call("list_custom_fields") ]
    @connector.refresh

    secrets = Regexp.union(PASSWORD, ACCESS, REFRESH, FRESH, "clio-refresh-9944")
    assert_no_match secrets, answers.to_json
    assert_match "Clio refused: Forbidden", answers.last.dig("content", 0, "text")
    assert_match "mcp_servers", log.string, "the queries were logged"
    assert_no_match secrets, log.string
    assert_no_match secrets, @connector.reload.inspect
  ensure
    Rails.logger.stop_broadcasting_to(capture) if capture
  end

  test "an entry saved for another site is not sent to Clio, and the call says why" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Clio app", uri: "https://clio.example.com")
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 30.seconds.from_now.to_i))
    token = stub_request(:post, TOKEN_URL)

    error = assert_raises(McpServer::Unreachable) { call("list_calendars") }

    assert_match "Clio app is saved for clio.example.com, not app.clio.com", error.message
    assert_not_requested token
  end

  test "it needs a vault entry, and that entry is the app's, never the agent's to use" do
    missing = @agent.user.mcp_servers.build(name: "clio2", **McpServer.gallery_attributes(:clio))
    assert_not missing.valid?
    assert_includes missing.errors[:vault_entry], "can't be blank"

    assert @agent.reload.reserved_sign_in?("clio APP")
    assert_not @agent.reserved_sign_in?("Bank")
  end

  private
    def call(tool, arguments = {}) = @connector.call_tool(tool, arguments)

    def receive(conversation, tool, arguments, call_id)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
      conversation.invocations.find_by!(call_id: call_id)
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
end
