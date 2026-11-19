require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# An agent's own calendar on a CalDAV server of its own (#77,
# docs/calendar.md, "Its own calendar server"): its owner names the
# account's calendar home and a vault entry, and the calendar tools use that
# account instead of the install's. The fake `passbolt` command and the two
# CalDAV servers (WebMock) are the only stand-ins; the tools, the ledger, the
# job and the client run for real.
class AgentCalendarServerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include CaldavTestHelper
  include PassboltTestHelper

  KEY = PassboltTestHelper::PASSWORD
  SERVER = "https://dav.mail.example.com"
  HOME = "/dav/calendars/user/desk@mail.example.com/"

  setup do
    install_sidecar_settings
    install_caldav(username: "agent-1", password: "app-password")
    install_fake_passbolt(name: "Desk calendar", uri: SERVER)
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(time_zone: "Eastern Time (US & Canada)", caldav_username: "agent-1", caldav_password: "app-password")
    @agent.create_calendar_server!(url: SERVER + HOME, vault_entry: "Desk calendar")
    @conversation = create_conversation(@agent)
    own_server
  end
  teardown do
    remove_fake_passbolt
    remove_caldav
    remove_sidecar_settings
  end

  test "its calendar tools use its own server with the saved sign-in, in place of the install's account" do
    assert_not_includes passbolt_calls, "get resource", "nothing is read from the vault until a request is made"
    lists = call_tool("calendar_lists", {}, "c1")["result"]["lists"]
    assert_equal [ { "list" => "work", "name" => "Desk work", "kinds" => [ "events" ], "own" => true }, { "list" => "todo", "name" => "Desk to do", "kinds" => [ "tasks" ], "own" => true } ], lists

    saved = call_tool("calendar_save_event", { "list" => "work", "title" => "Supplier call", "start" => "2026-11-20T10:00" }, "c2")["result"]["saved"]
    assert_equal "Supplier call", Icalendar::Calendar.parse(@own.fetch(saved["id"]).last).first.events.sole.summary.to_s
    found = call_tool("calendar_find", { "kind" => "events", "list" => "work", "from" => "2026-11-19", "to" => "2026-11-21" }, "c3")["result"]["events"]
    assert_equal [ [ "work", saved["id"], "Supplier call" ] ], found.map { it.values_at("list", "id", "title") }
    call_tool("calendar_delete", { "list" => "work", "id" => saved["id"] }, "c4")
    assert_empty @own

    assert_not_requested :any, /\A#{Regexp.escape(CaldavTestHelper::URL)}/
    assert @own_requests.all? { |_, path| path == HOME || path.match?(%r{\A#{HOME}(work|todo)/([\w-]+\.ics)?\z}) }, @own_requests.inspect
  end

  test "unset, its calendar is the install's account as before" do
    @agent.calendar_server.destroy!
    assert_equal %w[ calendar tasks ], call_tool("calendar_lists", {}, "c1")["result"]["lists"].pluck("list")
    assert_empty @own_requests
  end

  test "its own server alone gives it the calendar tools, where the password manager is set up" do
    @agent.update!(caldav_username: nil, caldav_password: nil)
    remove_caldav
    assert @agent.reload.calendar?
    assert @conversation.reload.tool("calendar_find")

    remove_fake_passbolt
    assert_not @agent.reload.calendar?
  end

  test "the password goes only to the host saved with it" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Desk calendar", uri: "https://calendar.elsewhere.example")
    result = call_tool("calendar_lists", {}, "c1")
    assert result["isError"]
    assert_match "Desk calendar is saved for calendar.elsewhere.example, not dav.mail.example.com", result["result"].to_s
    assert_empty @own_requests
  end

  test "it reaches its home, its lists and their items, and nothing else on the server" do
    home = @agent.caldav
    [ [ "..", nil ], [ "work", "../../other/x" ], [ "work/..", nil ], [ "work", "x?depth=infinity" ], [ "../../principals", nil ] ].each do |list, id|
      assert_raises(DurableAssistants::Caldav::Error, [ list, id ].inspect) { id ? home.item(list, id) : home.items(list, "events") }
    end
    assert_empty @own_requests
    assert_not_includes passbolt_calls, "get resource", "a refused request reads nothing from the vault"
  end

  test "the password never reaches the result, the ledger, the log or the definition, even when the server echoes it" do
    @echo = true
    log = capture_log do
      result = call_tool("calendar_lists", {}, "c1")
      assert_equal "Desk work [the saved password]", result["result"]["lists"].first["name"]
      assert_not_includes result.to_json, KEY
    end
    assert_includes passbolt_calls, "get resource"
    assert_match "InvocationCallJob", log, "the log was read"
    assert_not_includes log, KEY
    assert_not_includes @conversation.invocations.reload.map(&:attributes).to_json, KEY
    assert_not_includes @agent.reload.definition(@conversation.tools).to_json, KEY
    assert_not_includes Agent::CalendarServer.connection.select_all("select * from agent_calendar_servers").to_a.to_json, KEY # tenancy-ok: the test's own row
    assert_not_includes @agent.caldav.inspect, KEY
  end

  private
    def call_tool(tool, arguments, call_id)
      post_call = -> { post "/agent/invocations", params: invocation_payload(@conversation, tool:, arguments:, call_id:), headers: rails_bearer, as: :json }
      post_call.call
      perform_enqueued_jobs(only: InvocationCallJob)
      post_call.call
      response.parsed_body
    end

    # The agent's own account on its own server: a home with a calendar and a task list.
    def own_server
      @own, @own_requests = {}, []
      stub_request(:any, /\A#{Regexp.escape(SERVER)}/).to_return do |request|
        path = request.uri.path
        @own_requests << [ request.method, path ]
        next { status: 401 } unless request.headers["Authorization"] == "Basic #{Base64.strict_encode64("maya:#{KEY}")}"
        list, file = path.delete_prefix(HOME).split("/", 2)
        id = file.presence&.delete_suffix(".ics")
        case request.method
        when :propfind
          path == HOME ? multistatus([ collection(HOME, "Desk", nil, owner: HOME), collection("#{HOME}work/", @echo ? "Desk work #{KEY}" : "Desk work", "VEVENT", owner: HOME), collection("#{HOME}todo/", "Desk to do", "VTODO", owner: HOME) ]) : { status: 404 }
        when :report then multistatus(@own.map { |key, (etag, ics)| item("#{HOME}#{list}/#{key}.ics", etag, ics) })
        when :get then @own[id] ? { status: 200, body: @own[id].last, headers: { "ETag" => @own[id].first } } : { status: 404 }
        when :put then (@own[id] = [ %("#{SecureRandom.hex(4)}"), request.body ]) && { status: 201 }
        when :delete then @own.delete(id) && { status: 204 }
        end
      end
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
