require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A sign-in from someone outside the install (a client's lawyer, say) that
# goes straight into the vault, never through an agent or a chat
# (docs/passwords.md, "From someone outside"). The agent asks for a link to an
# empty entry, the person approves every time, the outsider types the
# sign-in on a page of its own, and the agent hears only whether it was
# filled.
class SignInLinksTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include PassboltTestHelper

  # What the outsider types: each must reach passbolt-save's standard input
  # and nothing else.
  USERNAME = "outside-user-8812@example.com"
  SECRET = "harbour-lantern-5521-only-on-stdin"
  ACCOUNT = "ACCT-77310442"
  MARKERS = [ USERNAME, SECRET, ACCOUNT ].freeze

  setup do
    @access = Rails.application.config.x.access
    @previous_emails = @access[:emails]
    @access[:emails] = %w[ alice@example.com ]
    install_sidecar_settings
    install_fake_passbolt(password: "")
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@agent)
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json }
    }
  end
  teardown do
    @access[:emails] = @previous_emails
    travel_back
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "an agent with the saved sign-ins has the tool, and an agent stays within its tool limit" do
    assert @agent.conversation.tool("ask_outside_for_sign_in"), "looked up"
    assert_operator @agent.tool_count, :<=, Agent::TOOL_LIMIT
    with_setting(:passbolt, :url, nil) { assert_nil @agent.reload.conversation.tool("ask_outside_for_sign_in") }
  end

  test "the card asks every time, even where the install approves everything, and never offers Always" do
    with_setting(:app, :approve_everything, true) do
      with_setting(:app, :approvals, "allow") do
        assert_equal "waiting", invoke("ask_outside_for_sign_in", { "name" => "Bank" })["status"]
        invocation = @conversation.invocations.sole
        assert invocation.awaiting_person?
        assert_empty invocation.always_choices, "never Always"
        assert_raises(ArgumentError) { invocation.approve!(by: @alice, always: "agent") }
        assert_empty passbolt_calls, "nothing is looked up before the person answers"

        assert_equal "waiting", invoke("ask_outside_for_sign_in", { "name" => "Bank" }, call_id: "toolu_2")["status"], "and the next one too"
      end
    end
  end

  test "approved, an empty entry gets a single link lasting 30 minutes, and the agent gets only the link and its expiry" do
    done = issue_link
    assert_equal %w[ expiresAt link ], done["result"].keys.sort
    assert_match %r{\Ahttp://localhost/sign_in_links/[A-Za-z0-9]{32,64}\z}, done["result"]["link"]
    link = @conversation.sign_in_links.sole
    assert_in_delta 30.minutes.from_now, Time.iso8601(done["result"]["expiresAt"]), 5
    assert_in_delta 30.minutes.from_now, link.expires_at, 5
    assert_equal [ "7f0c", "Bank" ], [ link.entry_id, link.name ]
    token = done["result"]["link"].split("/").last
    assert_not_includes link.attributes.to_json, token, "only its digest is kept"
    assert_equal link, SignInLink.find_by_token(token)
  end

  # The tool is looked up, so the model calls it by name once tool_search finds it.
  test "looked up, an approved call makes the link" do
    assert_includes @conversation.lookup_tools.map(&:tool_name), "ask_outside_for_sign_in"
    used = { "name" => "Bank" }

    assert_equal "waiting", invoke("ask_outside_for_sign_in", used)["status"], "it asks"
    invocation = @conversation.invocations.sole
    assert_equal :approval, invocation.asks
    assert_empty invocation.always_choices, "never Always"
    invocation.approve!(by: @alice)
    invoke("ask_outside_for_sign_in", used)
    perform_enqueued_jobs(only: InvocationCallJob)
    done = invoke("ask_outside_for_sign_in", used)

    assert_not done["isError"], done.to_json
    assert_match %r{\Ahttp://localhost/sign_in_links/[A-Za-z0-9]{32,64}\z}, done["result"]["link"]
    link = @conversation.sign_in_links.sole
    assert_equal [ invocation, "7f0c", "Bank" ], [ link.invocation, link.entry_id, link.name ]
  end

  test "a non-empty entry is refused at tool time, saying the owner must empty it first, and makes no link" do
    remove_fake_passbolt
    install_fake_passbolt # it has a password
    done = issue_link
    assert done["isError"]
    assert_match "already has a password", done.to_json
    assert_match "empty it first", done.to_json
    assert_empty @conversation.sign_in_links
    assert_no_match "SAVE", passbolt_calls, "nothing is written"
  end

  test "an entry that is not shared with the agent is refused" do
    done = issue_link(name: "Brokerage")
    assert done["isError"]
    assert_match "Nothing called Brokerage", done.to_json
    assert_empty @conversation.sign_in_links
  end

  test "opening the link shows a plain form and does not use it up; its page keeps no copy and gives no referrer" do
    path = link_path_from(issue_link)
    as_visitor do
      get path
      assert_response :success
      get path
      assert_response :success, "a mail scanner's fetch leaves it for the person"
      assert_select "form[action='#{path}/fill'][method=post][autocomplete=off]" do
        assert_select "input[name='sign_in[username]'][autocomplete=off]"
        assert_select "input[type=password][name='sign_in[password]'][autocomplete=off]"
        assert_select "input[name='sign_in[account]'][autocomplete=off]"
      end
      assert_match "Bank", response.body
      assert_select "script", 0, "no scripts, ours or anyone's"
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal "no-referrer", response.headers["Referrer-Policy"]
    end
    assert_nil @conversation.sign_in_links.sole.used_at
  end

  test "a submit writes to the vault on standard input only: never argv, the log, a row, a job or the thread" do
    path = link_path_from(issue_link)
    log = capture_log do
      as_visitor do
        get path
        post "#{path}/fill", params: { sign_in: { username: USERNAME, password: SECRET, account: ACCOUNT } }
        assert_response :success
        assert_match "Saved", response.body
        MARKERS.each { assert_not_includes response.body, it }
      end
    end

    saves = passbolt_calls.lines.grep(/\ASAVE /)
    assert_equal [ "SAVE ARGS fill\n" ], saves.grep(/\ASAVE ARGS/), "one write, in fill mode, with nothing secret in its arguments"
    input = JSON.parse(saves.grep(/\ASAVE INPUT/).sole.delete_prefix("SAVE INPUT "))
    assert_equal({ "id" => "7f0c", "username" => USERNAME, "password" => SECRET, "account" => ACCOUNT }, input)
    assert_match "AS the shared user", passbolt_calls

    assert_match "SignInLinks::FillsController#create", log, "the log was read"
    jobs = enqueued_jobs.inspect
    perform_enqueued_jobs(only: SignInLinkReportJob)
    assert_match "filled", @submissions.sole["content"]
    rows = every_row
    MARKERS.each do |marker|
      assert_not_includes log, marker
      assert_not_includes rows, marker
      assert_not_includes jobs, marker
      assert_not_includes @submissions.to_json, marker
      assert_not_includes passbolt_calls.lines.grep_v(/\ASAVE INPUT/).join, marker
    end
    link = @conversation.sign_in_links.sole
    assert_equal "filled", link.outcome
    assert link.used_at
  end

  test "a used link is refused, and nothing is written twice" do
    path = link_path_from(issue_link)
    as_visitor { fill(path) }
    as_visitor do
      get path
      assert_response :gone
      assert_match "already been used", response.body
      fill(path)
      assert_response :gone
    end
    assert_equal 1, passbolt_calls.scan("SAVE ARGS").size
  end

  test "an expired link is refused, and the agent hears it expired unused" do
    path = link_path_from(issue_link)
    travel SignInLink::LASTS + 1.second
    as_visitor do
      get path
      assert_response :gone
      assert_match "expired", response.body
      fill(path)
      assert_response :gone
    end
    assert_no_match "SAVE", passbolt_calls

    perform_enqueued_jobs(only: SignInLinkExpiryJob)
    perform_enqueued_jobs(only: SignInLinkReportJob)
    assert_equal "expired", @conversation.sign_in_links.sole.outcome
    assert_match "expired unused", @submissions.sole["content"]
  end

  test "a submit from a second browser after the first is refused" do
    path = link_path_from(issue_link)
    first, second = open_session, open_session
    first.get path
    second.get path
    assert_equal [ 200, 200 ], [ first.response.status, second.response.status ]

    first.post "#{path}/fill", params: { sign_in: { username: USERNAME, password: SECRET } }
    second.post "#{path}/fill", params: { sign_in: { username: "other@example.com", password: "another-try" } }
    assert_equal 200, first.response.status
    assert_equal 410, second.response.status
    assert_match "already been used", second.response.body
    assert_equal 1, passbolt_calls.scan("SAVE ARGS").size
    assert_no_match "another-try", passbolt_calls
  end

  test "the person revokes the link from its card; then it is refused and the agent hears it was not filled" do
    path = link_path_from(issue_link)
    sign_in_via_ajent(name: "Alice", subject: "sub-alice", email: "alice@example.com")
    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "Here is a link.",
      tool_calls: [ { "id" => "toolu_1", "name" => "ask_outside_for_sign_in", "arguments" => { "name" => "Bank" } } ])
    get conversation_path(@conversation)
    link = @conversation.sign_in_links.sole
    assert_select ".sign-in-link", text: /Open until/
    assert_select "form[action='#{conversation_sign_in_link_path(@conversation, link)}'] button", text: "Revoke"

    delete conversation_sign_in_link_path(@conversation, link)
    assert_response :see_other
    assert_equal "revoked", link.reload.outcome
    assert_equal @alice, link.revoked_by

    as_visitor do
      get path
      assert_response :gone
      assert_match "revoked", response.body
    end
    perform_enqueued_jobs(only: SignInLinkReportJob)
    assert_match "not filled", @submissions.sole["content"]
    assert_match "revoked", @submissions.sole["content"]
  end

  test "a failed write is said plainly, the link can't be tried again, and the agent hears it was not filled" do
    path = link_path_from(issue_link)
    fail_passbolt_save!
    as_visitor do
      fill(path)
      assert_response :bad_gateway
      assert_match "could not be saved", response.body
      fill(path)
      assert_response :gone
    end
    assert_equal 1, passbolt_calls.scan("SAVE ARGS").size
    assert_equal "failed", @conversation.sign_in_links.sole.outcome
    perform_enqueued_jobs(only: SignInLinkReportJob)
    assert_match "not filled", @submissions.sole["content"]
    MARKERS.each { assert_not_includes @submissions.to_json, it }
  end

  test "a blank username or password asks again without using the link up" do
    path = link_path_from(issue_link)
    as_visitor do
      post "#{path}/fill", params: { sign_in: { username: USERNAME, password: "" } }
      assert_response :unprocessable_entity
      assert_match "Type the username and password", response.body
      MARKERS.each { assert_not_includes response.body, it }
      fill(path)
      assert_response :success
    end
    assert_equal 1, passbolt_calls.scan("SAVE ARGS").size
  end

  # A page that sends no referrer posts its form with Origin "null"; Rails'
  # check of the browser's own Sec-Fetch-Site still turns away another site.
  test "with forgery protection on, the page's own form posts and another site's does not" do
    path = link_path_from(issue_link)
    with_forgery_protection do
      as_visitor do
        post "#{path}/fill", params: { sign_in: { username: USERNAME, password: SECRET } }, headers: { "Origin" => "https://elsewhere.example", "Sec-Fetch-Site" => "cross-site" }
        assert_not response.successful?
        assert_no_match "SAVE", passbolt_calls
        post "#{path}/fill", params: { sign_in: { username: USERNAME, password: SECRET } }, headers: { "Origin" => "null", "Sec-Fetch-Site" => "same-origin" }
        assert_response :success
      end
    end
  end

  test "an unknown or malformed token is not found, and an address may open 30 a minute and send 10" do
    as_visitor do
      get "/sign_in_links/#{"x" * 40}"
      assert_response :not_found
      29.times { get "/sign_in_links/nope" }
      get "/sign_in_links/nope"
      assert_response :too_many_requests

      10.times { post "/sign_in_links/nope/fill", params: { sign_in: { username: "a", password: "b" } } }
      assert_response :not_found
      post "/sign_in_links/nope/fill", params: { sign_in: { username: "a", password: "b" } }
      assert_response :too_many_requests
    end
  end

  private
    def invoke(tool, arguments, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    # The agent asks, the person approves, the call runs: its outcome.
    def issue_link(name: "Bank")
      invoke("ask_outside_for_sign_in", { "name" => name })
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("ask_outside_for_sign_in", { "name" => name })
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke("ask_outside_for_sign_in", { "name" => name })
    end

    def link_path_from(done) = URI(done.dig("result", "link")).path

    def fill(path) = post("#{path}/fill", params: { sign_in: { username: USERNAME, password: SECRET, account: ACCOUNT } })

    def as_visitor
      saved = cookies.to_hash
      reset!
      yield
    ensure
      reset!
      saved.each { |name, value| cookies[name] = value }
    end

    def every_row
      connection = ActiveRecord::Base.connection
      connection.tables.map { connection.select_all("SELECT * FROM #{connection.quote_table_name(it)}").to_a }.to_json
    end

    def with_forgery_protection
      previous, ActionController::Base.allow_forgery_protection = ActionController::Base.allow_forgery_protection, true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    def capture_log
      output = StringIO.new
      logger = ActiveSupport::Logger.new(output)
      previous = Rails.logger
      Rails.logger = ActiveSupport::BroadcastLogger.new(previous, logger)
      ActionController::Base.logger = Rails.logger
      yield
      output.string
    ensure
      Rails.logger = previous
      ActionController::Base.logger = previous
    end
end
