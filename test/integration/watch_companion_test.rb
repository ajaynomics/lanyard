require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/email_test_helper"

# The Watch calls Rails itself, with a token of its own that the phone asked
# for over the person's web session (#7): the agents to write to, the cards
# waiting, an answer bound to the card shown, and a message under its request
# id, and a thread's newest turns to read (#78). The token opens those
# actions as JSON and nothing else; revoked or unknown, it gets 401. Nothing
# succeeds without saying so.
class WatchCompanionTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper

  JSON_HEADERS = { "Accept" => "application/json" }.freeze

  setup do
    install_sidecar_settings
    install_email_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(status: 200, body: { rung: true }.to_json)
    @token = mint
    # From here on the Watch has its token and no session.
    delete sign_out_path
  end
  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "the phone, signed in, gets a token for its Watch; only the token's digest is kept" do
    watch = @user.watches.sole
    assert_equal "Robin's Watch", watch.name
    assert_equal Digest::SHA256.hexdigest(@token), watch.token_digest
    assert_operator @token.length, :>=, 32
    assert_nil watch.last_used_at

    post watches_path, params: { name: "Another" }, as: :json
    assert_response :unauthorized
    assert_equal 1, @user.watches.count
  end

  test "over https the phone's asking needs its same-origin header; the Watch's token needs none" do
    https!
    sign_in_via_ajent
    with_forgery_protection do
      post watches_path, params: { name: "Watch" }, as: :json
      assert_response :unprocessable_entity
      post watches_path, params: { name: "Watch" }, as: :json, headers: { "Sec-Fetch-Site" => "same-origin" }
      assert_response :created
      delete sign_out_path, headers: { "Sec-Fetch-Site" => "same-origin" }

      invocation = waiting("forget_note", { "key" => "trip" })
      on_watch :post, conversation_invocation_approval_path(@conversation, invocation),
        params: { decision: "deny", version: Invocation::Card.new(invocation).version }
      assert_response :ok
      assert invocation.reload.denied?
    end
  end

  test "the list is the person's agents and their waiting approvals, each card whole" do
    forget = waiting("forget_note", { "key" => "trip" })
    waiting("ask_person", { "question" => "Which day?", "options" => %w[ Monday Tuesday ] }, call_id: "toolu_2")
    mallory = create_user(name: "Mallory")
    waiting("forget_note", { "key" => "theirs" }, conversation: create_conversation(mallory.agents.sole, durable_id: "99"))

    on_watch :get, conversations_path

    assert_response :ok
    body = response.parsed_body
    assert_equal [ [ @conversation.id, @agent.to_s ] ], body["agents"].map { it.values_at("conversation_id", "name") }
    card = body["approvals"].sole
    assert_equal forget.id, card["id"]
    assert_equal @agent.to_s, card["agent"]
    assert_equal "Allow forget note?", card["title"]
    assert_equal [ { "label" => "Key", "text" => "trip" } ], card["fields"]
    assert_equal "awaiting_person", card["state"]
    assert card["small"]
    assert_equal Invocation::Card.new(forget).version, card["version"]
    assert_not_includes response.headers["Set-Cookie"].to_s, "_durable_assistants_session", "a token never starts a session"
  end

  # A notice from a shared workspace's agent reaches a member's phone, and so
  # their Watch: its list holds every workspace of theirs, and it answers there.
  test "a shared workspace's card is on a member's Watch and answered from it, until they are removed" do
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: create_user(name: "Alice"), role: "owner")
    membership = shared.memberships.create!(user: @user, role: "member")
    conversation = create_conversation(shared.owner.start_agent("Iris", workspace: shared), durable_id: "50")
    card = waiting("forget_note", { "key" => "shared" }, conversation: conversation)

    on_watch :get, conversations_path
    assert_equal [ conversation.id, @conversation.id ].sort, response.parsed_body["agents"].map { it["conversation_id"] }.sort
    assert_includes response.parsed_body["approvals"].map { it["id"] }, card.id
    on_watch :post, conversation_invocation_approval_path(conversation, card), params: { decision: "deny", version: Invocation::Card.new(card).version }
    assert_response :ok
    assert card.reload.denied?

    membership.destroy!
    other = waiting("forget_note", { "key" => "later" }, conversation: conversation)
    on_watch :get, conversations_path
    assert_not_includes response.parsed_body["approvals"].map { it["id"] }, other.id
    assert_not_includes response.parsed_body["agents"].map { it["conversation_id"] }, conversation.id
    on_watch :post, conversation_invocation_approval_path(conversation, other), params: { decision: "deny", version: Invocation::Card.new(other).version }
    assert_response :not_found
    assert other.reload.awaiting_person?
  end

  test "using the token marks the Watch used" do
    freeze_time
    on_watch :get, conversations_path
    assert_equal Time.current, @user.watches.sole.last_used_at
  end

  test "a revoked or unknown token, or none, is refused with 401 and decides nothing" do
    invocation = waiting("forget_note", { "key" => "trip" })
    params = { decision: "approve", version: Invocation::Card.new(invocation).version }

    [ "not-a-token", "" ].each do |token|
      on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: params, token: token
      assert_response :unauthorized
    end
    post conversation_invocation_approval_path(@conversation, invocation), params: params, as: :json
    assert_response :unauthorized

    @user.watches.sole.revoke!
    on_watch :get, conversations_path
    assert_response :unauthorized
    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: params
    assert_response :unauthorized
    assert invocation.reload.awaiting_person?
  end

  test "Settings lists the person's Watches, and Revoke refuses that token at once" do
    on_watch :get, conversations_path
    sign_in_via_ajent
    get settings_watches_path
    watch = @user.watches.sole
    assert_select "#watches_title", "Apple Watch"
    assert_select "li", text: /Robin's Watch\s+Last used/ do
      assert_select "form[action=?] button[aria-label=?]", watch_path(watch), "Revoke Robin's Watch", text: "Revoke"
    end

    delete watch_path(watch)
    assert_redirected_to settings_watches_path
    assert watch.reload.revoked_at
    on_watch :get, conversations_path
    assert_response :unauthorized
    get settings_watches_path
    assert_select "#watches", text: /No Apple Watch is connected/
    assert_select "#watches button", count: 0

    mallory = create_user(name: "Mallory")
    theirs = mallory.watches.create!(name: "Mallory's Watch")
    delete watch_path(theirs)
    assert_response :not_found
    assert_nil theirs.reload.revoked_at
  end

  test "a token opens only the Watch's actions, as JSON, and a session never stands in for it" do
    on_watch :get, conversation_path(@conversation)
    assert_response :unauthorized
    get conversations_path, headers: { "Authorization" => "Bearer #{@token}" }
    assert_redirected_to sign_in_path
    on_watch :get, settings_account_path
    assert_response :unauthorized
    on_watch :post, watches_path, params: { name: "Spare" }
    assert_response :unauthorized
    on_watch :post, conversation_cancellations_path(@conversation)
    assert_response :unauthorized
    assert_equal 1, @user.watches.count

    sign_in_via_ajent
    @user.watches.sole.revoke!
    on_watch :get, conversations_path
    assert_response :unauthorized
    get conversations_path, headers: JSON_HEADERS
    assert_response :ok
  end

  test "an admitted person taken off the list is refused at once, token and all" do
    with_setting(:access, :emails, [ "member@example.com" ]) do
      on_watch :get, conversations_path
      assert_response :unauthorized
    end
    on_watch :get, conversations_path
    assert_response :ok
  end

  test "without a session or a token, data is refused, not a page to sign in on" do
    get conversations_path, headers: JSON_HEADERS
    assert_response :unauthorized
  end

  test "allowing the card shown decides it once; the same answer again is that answer, and a different one conflicts" do
    invocation = waiting("forget_note", { "key" => "trip" })
    version = Invocation::Card.new(invocation).version

    2.times do
      on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", version: version }
      assert_response :ok
      assert_equal "approve", response.parsed_body["decision"]
    end
    assert invocation.reload.approved?
    assert_equal @user, invocation.approval.decided_by
    assert_equal 1, Approval.where(invocation: invocation).count # tenancy-ok: counts this test's call
    assert_enqueued_jobs 1, only: InvocationWakeJob

    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny", version: version }
    assert_response :conflict
    assert_equal "answered_or_expired", response.parsed_body["error"]
    assert invocation.reload.approved?
  end

  test "a card that changed since it was shown, or no card named, is refused" do
    invocation = waiting("send_email", { "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Two nights." })
    shown = Invocation::Card.new(invocation).version
    invocation.update!(preview: { "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Three nights.", "digest" => "d2" })

    [ shown, nil ].each do |version|
      on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", version: version }.compact
      assert_response :conflict
      assert_equal "changed", response.parsed_body["error"]
      assert_equal [ "Three nights." ], response.parsed_body["fields"].filter_map { it["text"] if it["label"] == "Body" }
    end
    assert invocation.reload.awaiting_person?
    assert_nil invocation.approval
  end

  # Declining is always safe, so a card that changed since it was shown is
  # still declined from it: only Allow asks for the card as it is now.
  test "Decline from a card that changed since it was shown declines it, once; Allow from it is still refused" do
    invocation = waiting("send_email", { "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Two nights." })
    shown = Invocation::Card.new(invocation).version
    invocation.update!(preview: { "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Three nights.", "digest" => "d2" })

    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", version: shown }
    assert_equal [ 409, "changed" ], [ response.status, response.parsed_body["error"] ]

    [ shown, nil, shown ].each do |version|
      on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny", version: version }.compact
      assert_response :ok
      assert_equal "deny", response.parsed_body["decision"]
    end
    assert invocation.reload.denied?
    assert_equal 1, Approval.where(invocation: invocation).count # tenancy-ok: counts this test's call
  end

  test "a sign-in card is declined from the Watch whatever version it names" do
    @agent.create_computer!(provider: "sprites", state: "on")
    install_fake_passbolt
    invocation = waiting("ask_for_sign_in", { "name" => "Bank", "site" => "https://bank.example/login", "why" => "To pay the bill." })
    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny", version: "stale" }
    assert_response :ok
    assert invocation.reload.denied?
  ensure
    remove_fake_passbolt
  end

  test "an expired or another person's card cannot be decided" do
    invocation = waiting("forget_note", { "key" => "trip" })
    version = Invocation::Card.new(invocation).version
    invocation.update!(expires_at: 1.minute.ago)
    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", version: version }
    assert_response :conflict
    assert_equal "answered_or_expired", response.parsed_body["error"]
    assert invocation.reload.awaiting_person?

    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.agents.sole, durable_id: "99")
    other = waiting("forget_note", { "key" => "theirs" }, conversation: theirs)
    on_watch :post, conversation_invocation_approval_path(theirs, other), params: { decision: "deny", version: Invocation::Card.new(other).version }
    assert_response :not_found
    assert other.reload.awaiting_person?
  end

  test "a long card is shown but allowed only on the phone; it can still be declined, and Always is never offered" do
    invocation = waiting("send_email", { "to" => [ "robin@example.com" ], "subject" => "Notes", "body" => "word " * 400 })
    card = Invocation::Card.new(invocation)
    assert_not card.small?

    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", version: card.version }
    assert_response :conflict
    assert_equal "phone_only", response.parsed_body["error"]
    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", version: card.version, always: "agent" }
    assert_response :bad_request
    assert invocation.reload.awaiting_person?

    on_watch :post, conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny", version: card.version }
    assert_response :ok
    assert invocation.reload.denied?
  end

  test "a message is accepted under its request id, the same id again is the same message, and acceptance is not a reply" do
    sent = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { |request| JSON.parse(request.body)["requestId"] == "watch-1" }
      .to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "not_ready" }.to_json)

    2.times do
      on_watch :post, conversation_submissions_path(@conversation), params: { content: "Plan Friday", request_id: "watch-1" }
      assert_response :accepted
      assert_equal({ "conversation_id" => @conversation.id, "request_id" => "watch-1", "accepted" => true }, response.parsed_body)
    end
    assert_requested sent, times: 1
  end

  # The person's own words steer (#85): sent from the Watch, or from a notice's
  # Reply, which choose no mode, they reach a working agent at its next step,
  # not once it has finished everything else.
  test "the person's message from the Watch steers a working agent" do
    sent = stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "not_ready" }.to_json)

    on_watch :post, conversation_submissions_path(@conversation), params: { content: "Stop, use Lisbon", request_id: "watch-steer" }
    assert_response :accepted
    assert_requested sent
    assert_requested(:post, "#{SIDECAR}/v1/conversations/12/submissions") { JSON.parse(it.body)["whenBusy"] == "steer" }
  end

  test "an unreachable agent is an error the Watch can read, not a success" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_timeout
    on_watch :post, conversation_submissions_path(@conversation), params: { content: "Plan Friday", request_id: "watch-2" }
    assert_not response.successful?
    assert response.parsed_body["error"].present?
  end

  test "the Watch reads a thread's newest turns as plain words, without marking it read" do
    @conversation.update_columns(read_at: nil)
    turn("user", "Book Lisbon", 1)
    turn("assistant", "Looking.", 2, tool_calls: [ { "id" => "t1", "name" => "list_notes", "arguments" => {} } ])
    turn("toolResult", "secret note contents", 3)
    turn("assistant", "**Booked** the [Friday flight](https://flights.example.com/1).", 4)

    on_watch :get, conversation_messages_path(@conversation)

    assert_response :ok
    body = response.parsed_body
    assert_equal [ @conversation.id, @agent.to_s, nil ], body.values_at("conversation_id", "agent", "earlier")
    assert_equal [ [ "user", "Book Lisbon" ], [ "assistant", "Looking." ], [ "assistant", "Booked the Friday flight." ] ],
      body["messages"].map { it.values_at("role", "text") }
    assert body["messages"].all? { it["id"].is_a?(Integer) && Time.iso8601(it["at"]) }
    assert_no_match(/secret note|flights\.example|\*\*/, response.body)
    assert_nil @conversation.reload.read_at, "reading on the Watch is not opening the thread"
    assert_not_includes response.headers["Set-Cookie"].to_s, "_durable_assistants_session"
  end

  # The token opens a thread's words as JSON only: the same request for the
  # HTML page (the earlier-messages frame) is not the Watch's, so it needs a
  # session, and without one it is sent to sign in with nothing of the thread.
  test "a Watch token asking for the thread's earlier messages as a page gets no thread, and as JSON gets it" do
    turn("user", "Book Lisbon", 1)
    turn("assistant", "Booked the Friday flight.", 2)

    [ { "Accept" => "text/html" }, { "Accept" => "*/*" } ].each do |accept|
      get conversation_messages_path(@conversation, before: 3), headers: accept.merge("Authorization" => "Bearer #{@token}")
      assert_response :redirect
      assert_match "/sign_in", response.location
      assert_no_match(/Lisbon|Friday flight/, response.body)
    end
    get conversation_messages_path(@conversation, before: 3, format: :html), headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :redirect
    assert_no_match(/Lisbon|Friday flight/, response.body)

    on_watch :get, conversation_messages_path(@conversation)
    assert_response :ok
    assert_equal [ "Book Lisbon", "Booked the Friday flight." ], response.parsed_body["messages"].pluck("text")
  end

  test "a long thread comes a page at a time, newest first, with where the earlier page ends" do
    25.times { turn(it.even? ? "user" : "assistant", "Turn #{it + 1}", it + 1) }

    on_watch :get, conversation_messages_path(@conversation)
    newest = response.parsed_body
    assert_equal (6..25).map { "Turn #{it}" }, newest["messages"].pluck("text")
    assert_equal 6, newest["earlier"]

    on_watch :get, conversation_messages_path(@conversation, before: newest["earlier"])
    assert_equal (1..5).map { "Turn #{it}" }, response.parsed_body["messages"].pluck("text")
    assert_nil response.parsed_body["earlier"]
  end

  test "a thread is read only with a live token, and only the person's own or a shared workspace's" do
    turn("user", "Book Lisbon", 1)
    get conversation_messages_path(@conversation), headers: JSON_HEADERS
    assert_response :unauthorized
    on_watch :get, conversation_messages_path(@conversation), token: "not-a-token"
    assert_response :unauthorized

    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.agents.sole, durable_id: "99")
    theirs.messages.create!(entry_key: "m1", entry_id: 1, role: "user", content: "Mallory's plans")
    on_watch :get, conversation_messages_path(theirs)
    assert_response :not_found
    assert_no_match(/Mallory's plans/, response.body)

    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: create_user(name: "Alice"), role: "owner")
    shared.memberships.create!(user: @user, role: "member")
    household = create_conversation(shared.owner.start_agent("Iris", workspace: shared), durable_id: "50")
    household.messages.create!(entry_key: "h1", entry_id: 1, role: "assistant", content: "Dinner at eight.")
    on_watch :get, conversation_messages_path(household)
    assert_response :ok
    assert_equal [ "Dinner at eight." ], response.parsed_body["messages"].pluck("text")

    @user.watches.sole.revoke!
    on_watch :get, conversation_messages_path(@conversation)
    assert_response :unauthorized
  end

  # The phone answers a notice's buttons (#78) with its web session, as JSON,
  # and gets no more than the Watch: Allow once on a small card shown at that
  # version, never a long one, never Always, and Reply under its request id.
  test "a notice's buttons answered on the phone, with its session, are held to the Watch's card" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "not_ready" }.to_json)
    sign_in_via_ajent
    long = waiting("send_email", { "to" => [ "robin@example.com" ], "subject" => "Notes", "body" => "word " * 400 })
    small = waiting("forget_note", { "key" => "trip" })
    answer = ->(card, decision, **extra) {
      post conversation_invocation_approval_path(@conversation, card), params: { decision: decision, version: Invocation::Card.new(card).version, **extra },
        as: :json, headers: JSON_HEADERS.merge("Sec-Fetch-Site" => "same-origin")
    }

    answer.(long, "approve")
    assert_equal [ 409, "phone_only" ], [ response.status, response.parsed_body["error"] ]
    answer.(small, "approve", always: "agent")
    assert_response :bad_request
    post conversation_invocation_approval_path(@conversation, small), params: { decision: "approve", version: "stale" }, as: :json, headers: JSON_HEADERS
    assert_equal "changed", response.parsed_body["error"]
    assert small.reload.awaiting_person?

    answer.(small, "approve")
    assert_response :ok
    assert small.reload.approved?
    assert_empty @agent.permissions
    answer.(long, "deny")
    assert long.reload.denied?

    post conversation_submissions_path(@conversation), params: { content: "Sounds good", request_id: "notice-1" }, as: :json, headers: JSON_HEADERS
    assert_response :accepted
  end

  test "the token never reaches the log" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "not_ready" }.to_json)
    invocation = waiting("forget_note", { "key" => "trip" })
    minted = nil
    log = logged do
      sign_in_via_ajent
      minted = mint
      on_watch :get, conversations_path, token: minted
      on_watch :get, conversation_messages_path(@conversation), token: minted
      on_watch :post, conversation_invocation_approval_path(@conversation, invocation),
        params: { decision: "deny", version: Invocation::Card.new(invocation).version }, token: minted
      on_watch :post, conversation_submissions_path(@conversation), params: { content: "Hi", request_id: "watch-3", token: minted }, token: minted
    end

    assert_operator log.scan("Parameters").size, :>=, 4
    assert_no_match minted, log
    assert_no_match @user.watches.last.token_digest, log
  end

  private
    def mint
      post watches_path, params: { name: "Robin's Watch" }, as: :json
      assert_response :created
      response.parsed_body.fetch("token")
    end

    def on_watch(verb, path, params: nil, token: @token)
      process verb, path, params: params, as: (:json unless verb == :get),
        headers: JSON_HEADERS.merge("Authorization" => "Bearer #{token}")
    end

    def turn(role, content, entry_id, tool_calls: [])
      @conversation.messages.create!(entry_key: "e#{entry_id}", entry_id: entry_id, role: role, content: content, tool_calls: tool_calls)
    end

    def waiting(tool, arguments, conversation: @conversation, call_id: "toolu_#{tool}_#{arguments.hash.abs}")
      digest = Invocation.digest_for(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments)
      Invocation.receive(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments, digest: digest)
      conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "#{tool} should wait for the person" }
    end

    def with_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    def logged
      log = StringIO.new
      logger, ActionController::Base.logger = ActionController::Base.logger, ActiveSupport::Logger.new(log)
      yield
      log.string
    ensure
      ActionController::Base.logger = logger
    end
end
