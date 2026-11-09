require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class McpServer::GoogleTest < ActiveSupport::TestCase
  include AgentTestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  CALENDAR = "https://www.googleapis.com/calendar/v3".freeze

  setup do
    @agent = create_user.agents.sole
    @invocation = Invocation.new(conversation: create_conversation(@agent))
  end

  test "a connector to Google's hosted servers lists this app's own tools, whatever it stored" do
    gmail = connector("gmail", tools: [ { "name" => "trash_thread", "description" => "old", "input_schema" => {}, "annotations" => {} } ])
    calendar = connector("calendar")
    names = @agent.conversation.tools.map(&:tool_name)

    assert_includes names, "mcp__gmail__search_threads"
    assert_includes names, "mcp__gmail__send_message"
    assert_includes names, "mcp__calendar__create_event"
    assert_not_includes names, "mcp__gmail__trash_thread"
    assert_equal :gmail, gmail.google
    assert_equal :calendar, calendar.google
    assert_nil McpServer.new(url: "https://mcp.example.com/mcp").google

    gmail.refresh
    assert_equal McpServer::Google.listing(:gmail).pluck("name"), gmail.reload.tools.pluck("name")
    assert_nil gmail.refresh_error
  end

  test "reading runs at once; sending, deleting and changing ask the person" do
    connector("gmail")
    connector("calendar")
    conversation = @agent.conversation

    %w[ mcp__gmail__search_threads mcp__gmail__get_thread mcp__calendar__list_events ].each { assert_nil conversation.tool(it).asks, it }
    %w[ mcp__gmail__send_message mcp__gmail__send_draft mcp__gmail__delete_draft mcp__gmail__create_draft
        mcp__calendar__create_event mcp__calendar__delete_event ].each { assert_equal :approval, conversation.tool(it).asks, it }
  end

  test "sending mail and deleting an event wait for the person even where the install approves everything; other changes don't" do
    connector("gmail")
    connector("calendar")
    conversation = @invocation.conversation

    with_setting(:app, :approve_everything, true) do
      send = receive(conversation, "mcp__gmail__send_message", { "to" => [ "sam@example.com" ], "body" => "Tuesday." }, "c1")
      assert send.awaiting_person?, "a send shows its approval card"
      assert_empty send.always_choices, "and offers no Always"
      assert receive(conversation, "mcp__gmail__send_draft", { "draft_id" => "d1" }, "c2").awaiting_person?
      assert receive(conversation, "mcp__calendar__delete_event", { "event_id" => "e1" }, "c3").awaiting_person?
      assert_not receive(conversation, "mcp__gmail__create_draft", { "to" => [ "sam@example.com" ], "body" => "Draft" }, "c4").awaiting_person?
      assert_not receive(conversation, "mcp__calendar__create_event", { "summary" => "Call", "start" => "2026-11-20", "end" => "2026-11-21" }, "c5").awaiting_person?
    end
  end

  test "a send looked up with find_tools still waits for the person where the install approves everything" do
    connector("gmail").update!(loaded: false)
    conversation = @invocation.conversation

    with_setting(:app, :approve_everything, true) do
      call = receive(conversation, "use_tool", { "name" => "mcp__gmail__send_message", "arguments" => { "to" => [ "sam@example.com" ], "body" => "Hi." } }, "c1")
      assert call.awaiting_person?
      assert_empty call.always_choices
    end
  end

  test "the Permissions page says which of them still ask where the install approves everything" do
    connector("gmail")
    connector("calendar")
    with_setting(:app, :approve_everything, true) do
      html = ApplicationController.render("agents/permissions/index", assigns: { agent: @agent }, layout: false)
      assert_match "To delete event (calendar), send draft (gmail), and send message (gmail) it still asks every time.", html
    end
  end

  test "search lists each thread's subject, latest sender and snippet, with the connector's token" do
    connector("gmail")
    stub_request(:get, "#{GMAIL}/threads").with(query: { q: "from:sam", maxResults: "10" }, headers: { "Authorization" => "Bearer access-1" })
      .to_return(json(threads: [ { id: "t1" } ], nextPageToken: "p2"))
    stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including(format: "metadata"))
      .to_return(json(messages: [ gmail_message("m1", "Robin <robin@example.com>", "Lunch", labels: %w[ INBOX ]),
        gmail_message("m2", "Sam <sam@example.com>", "Re: Lunch", labels: %w[ INBOX UNREAD ], snippet: "Tuesday works") ]))

    result = call("mcp__gmail__search_threads", query: "from:sam")

    thread = result["threads"].sole
    assert_equal [ "t1", "Lunch", "Sam <sam@example.com>", "Tuesday works", 2, true ], thread.values_at("thread_id", "subject", "from", "snippet", "messages", "unread")
    assert_equal "p2", result["next_page_token"]
  end

  test "a thread reads as text: plain where it has it, its HTML without markup where not" do
    connector("gmail")
    plain = gmail_message("m1", "Sam <sam@example.com>", "Plan", parts: [ part("text/plain", "See you at noon."), part("text/html", "<p>See you at noon.</p>"),
      { "mimeType" => "application/pdf", "filename" => "menu.pdf", "body" => { "size" => 1200 } } ])
    html = gmail_message("m2", "Robin <robin@example.com>", "Re: Plan", parts: [ part("text/html", "<div>Great,<br>see <b>you</b> then</div>") ])
    stub_request(:get, "#{GMAIL}/threads/t1").with(query: { format: "full" }).to_return(json(id: "t1", messages: [ plain, html ]))

    messages = call("mcp__gmail__get_thread", thread_id: "t1")["messages"]

    assert_equal "See you at noon.", messages.first["text"]
    assert_equal [ { "name" => "menu.pdf", "type" => "application/pdf", "size" => 1200 } ], messages.first["attachments"]
    assert_match "see you then", messages.last["text"].squish
    assert_no_match "<b>", messages.last["text"]
  end

  test "a reply goes into its thread with the headers that keep it there" do
    connector("gmail")
    stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including(format: "metadata"))
      .to_return(json(messages: [ gmail_message("m1", "Sam <sam@example.com>", "Lunch", extra: { "Message-ID" => "<a@example.com>" }) ]))
    sent = stub_request(:post, "#{GMAIL}/messages/send").with { |request|
      body = JSON.parse(request.body)
      raw = Base64.urlsafe_decode64(body["raw"])
      body["threadId"] == "t1" && raw.include?("Subject: Re: Lunch") && raw.include?("In-Reply-To: <a@example.com>") &&
        raw.include?("To: sam@example.com") && raw.include?("Tuesday at noon.")
    }.to_return(json(id: "m9", threadId: "t1"))

    result = call("mcp__gmail__send_message", to: [ "sam@example.com" ], body: "Tuesday at noon.", thread_id: "t1")

    assert_requested sent
    assert_equal({ "sent" => true, "message_id" => "m9", "thread_id" => "t1" }, result)
  end

  test "a draft is saved, changed and sent by its id" do
    connector("gmail")
    stub_request(:post, "#{GMAIL}/drafts").to_return(json(id: "d1", message: { id: "m1", threadId: "t1" }))
    stub_request(:put, "#{GMAIL}/drafts/d1").to_return(json(id: "d1", message: { id: "m2", threadId: "t1" }))
    stub_request(:post, "#{GMAIL}/drafts/send").with(body: { id: "d1" }.to_json).to_return(json(id: "m2", threadId: "t1"))

    assert_equal "d1", call("mcp__gmail__create_draft", to: [ "sam@example.com" ], subject: "Hi", body: "Draft")["draft_id"]
    assert_equal "m2", call("mcp__gmail__update_draft", draft_id: "d1", to: [ "sam@example.com" ], subject: "Hi", body: "Better")["message_id"]
    assert_equal true, call("mcp__gmail__send_draft", draft_id: "d1")["sent"]
  end

  test "an event is all-day when given dates, timed when given times, and an update sends only what changed" do
    connector("calendar")
    all_day = stub_request(:post, "#{CALENDAR}/calendars/primary/events").with(query: { sendUpdates: "none" },
      body: { summary: "Trip", start: { date: "2026-11-20" }, end: { date: "2026-11-23" } }.to_json).to_return(json(event("e1", "Trip")))
    timed = stub_request(:post, "#{CALENDAR}/calendars/work%40example.com/events").with(query: { sendUpdates: "all" },
      body: { summary: "Call", start: { dateTime: "2026-11-20T09:00:00", timeZone: "America/Toronto" },
              end: { dateTime: "2026-11-20T09:30:00", timeZone: "America/Toronto" }, attendees: [ { email: "sam@example.com" } ] }.to_json)
      .to_return(json(event("e2", "Call")))
    patched = stub_request(:patch, "#{CALENDAR}/calendars/primary/events/e1").with(query: { sendUpdates: "none" }, body: { location: "Lisbon" }.to_json)
      .to_return(json(event("e1", "Trip")))

    assert_equal "e1", call("mcp__calendar__create_event", summary: "Trip", start: "2026-11-20", end: "2026-11-23")["event_id"]
    call("mcp__calendar__create_event", calendar_id: "work@example.com", summary: "Call", start: "2026-11-20T09:00:00", end: "2026-11-20T09:30:00",
      time_zone: "America/Toronto", attendees: [ "sam@example.com" ], send_updates: "all")
    call("mcp__calendar__update_event", event_id: "e1", location: "Lisbon")

    assert_requested all_day
    assert_requested timed
    assert_requested patched
  end

  test "an expiring token is renewed with the connector's client first, and kept" do
    server = connector("calendar", expires_at: 30.seconds.from_now.to_i)
    renewed = stub_request(:post, "https://oauth2.googleapis.com/token")
      .with(body: { grant_type: "refresh_token", refresh_token: "refresh-1", client_id: "instance-id", client_secret: "instance-secret" })
      .to_return(json(access_token: "access-2", expires_in: 3600))
    stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: { "Authorization" => "Bearer access-2" }).to_return(json(items: []))

    call("mcp__calendar__list_calendars")

    assert_requested renewed
    tokens = server.reload.oauth_tokens
    assert_equal [ "access-2", "refresh-1" ], tokens.values_at("access_token", "refresh_token")
    assert_operator tokens["expires_at"], :>, 50.minutes.from_now.to_i
  end

  test "a token Google turns away is renewed once; a sign-in it won't renew asks the person" do
    server = connector("calendar")
    stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: { "Authorization" => "Bearer access-1" }).to_return(status: 401)
    stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: { "Authorization" => "Bearer access-2" }).to_return(json(items: []))
    stub_request(:post, "https://oauth2.googleapis.com/token").to_return(json(access_token: "access-2", expires_in: 3600))

    assert_equal({ "calendars" => [] }, call("mcp__calendar__list_calendars"))

    server.reload.update!(oauth_tokens: server.oauth_tokens.merge("access_token" => "access-1"))
    stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    error = assert_raises(Tool::Refusal) { call("mcp__calendar__list_calendars") }
    assert_match "needs the person to sign in again", error.message
    assert server.reload.sign_in_needed?
  end

  test "Google's refusal reaches the model in its own words" do
    connector("gmail")
    stub_request(:get, "#{GMAIL}/labels").to_return(status: 403, body: { error: { message: "Request had insufficient authentication scopes." } }.to_json)

    error = assert_raises(Tool::Refusal) { call("mcp__gmail__list_labels") }
    assert_match "insufficient authentication scopes", error.message
  end

  private
    def connector(kind, tools: [], expires_at: 1.hour.from_now.to_i)
      with_google_app do
        @agent.user.mcp_servers.create!(name: kind, **McpServer.gallery_attributes(kind), tools: tools, refreshed_at: Time.current,
          oauth_tokens: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => expires_at })
      end
    end

    def call(name, **arguments)
      with_google_app { @agent.reload.conversation.tool(name).new(@invocation).call(**arguments) }
    end

    def with_google_app
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
      yield
    ensure
      x.connectors = saved
    end

    def receive(conversation, tool, arguments, call_id)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      with_google_app { Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest]) }
      conversation.invocations.find_by!(call_id: call_id)
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }

    def gmail_message(id, from, subject, labels: [], snippet: nil, parts: nil, extra: {})
      headers = { "From" => from, "Subject" => subject, "Date" => "Mon, 9 Nov 2026 10:00:00 -0500", **extra }.map { |name, value| { "name" => name, "value" => value } }
      { "id" => id, "threadId" => "t1", "labelIds" => labels, "snippet" => snippet, "payload" => { "mimeType" => "multipart/mixed", "headers" => headers, "parts" => parts }.compact }
    end

    def part(type, text) = { "mimeType" => type, "filename" => "", "body" => { "data" => Base64.urlsafe_encode64(text) } }

    def event(id, summary) = { id: id, summary: summary, start: { date: "2026-11-20" }, end: { date: "2026-11-23" } }
end
