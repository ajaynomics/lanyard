require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Payments by one-time card from a person's Link wallet (docs/payments.md).
# The person approves each one in Link's app, never here and never "always";
# Link is never sent an approval policy. The card goes to the sidecar once,
# for the browser, and never into the model's result, the ledger or the logs.
# A card that won't be used is closed at Link: on expiry, on failure, and when
# the person cancels. Link here is a stand-in at the HTTP boundary.
class LinkPaymentsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  NUMBER = "4000056655665556" # gitleaks:allow (a test card)
  # Letters, not digits: a made-up CVC that no timestamp or id in the log can contain by chance.
  CVC = "cvc-xq"
  API = DurableAssistants::Link::API
  SIGN_IN = DurableAssistants::Link::SIGN_IN
  ARGUMENTS = { "amount" => 2450, "currency" => "usd", "payee" => "Corner Books", "checkout_url" => "https://shop.example.com/checkout",
    "reason" => "Two paperbacks the person asked for this morning." }.freeze

  setup do
    install_sidecar_settings
    @link = Rails.application.config.x.link
    Rails.application.config.x.link = { client_id: "lwlpk_example", client_name: "Lanyard", test_mode: true }
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(tool_names: @agent.tool_names + [ "pay_by_card" ])
    @conversation = create_conversation(@agent)
    @alice.update!(link_session: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => 2.days.from_now.to_i,
      "connected_at" => Time.current.to_i })
    @sent, @ids = [], {}
    stub_request(:post, "#{API}/spend_requests").to_return do |request|
      @sent << (body = JSON.parse(request.body))
      id = @ids[body["idempotency_key"]] ||= "lsrq_#{@ids.size + 1}"
      json(id: id, status: "pending_approval", approval_url: "https://app.link.com/approve/#{id}")
    end
  end
  teardown do
    Rails.application.config.x.link = @link
    remove_sidecar_settings
  end

  test "the tool is off until a person switches it on, and is there only where the install has Link" do
    assert @agent.conversation.tool("pay_by_card")
    assert_nil @alice.personal_workspace.agents.create!(@agent.attributes.slice(*%w[ instructions model ]).merge(user: @alice, name: "Other")).conversation.tool("pay_by_card"), "off for every agent at first"
    Rails.application.config.x.link = {}
    assert_nil @agent.reload.conversation.tool("pay_by_card")
  end

  test "without a connected wallet the call is refused before anyone is asked, and Link hears nothing" do
    @alice.update!(link_session: nil)
    reply = invoke
    assert_equal "done", reply["status"]
    assert reply["isError"]
    assert_match "hasn't connected a Link wallet", reply["result"].to_s
    assert_nil @conversation.invocations.sole.payment_request
    assert_not_requested :any, /link\.com/
  end

  test "a person connects their own wallet with Link's phrase, and disconnecting ends the access at Link too" do
    @alice.update!(link_session: nil)
    stub_request(:post, "#{SIGN_IN}/device/code").to_return(json(device_code: "dev-1", user_code: "apple-banana", expires_in: 600,
      verification_uri: "https://app.link.com/device/setup", verification_uri_complete: "https://app.link.com/device/setup?code=apple-banana"))
    stub_request(:post, "#{SIGN_IN}/device/token").to_return(json({ error: "authorization_pending" }, http: 400),
      json(access_token: "access-2", refresh_token: "refresh-2", expires_in: 3600))
    stub_request(:post, "#{SIGN_IN}/device/revoke").to_return(json({}))
    sign_in_as @alice

    post settings_wallet_path
    follow_redirect!
    assert_select "#wallet_sign_in", text: /apple-banana/
    assert_requested(:post, "#{SIGN_IN}/device/code") { it.body.include?("client_id=lwlpk_example") && it.body.include?("connection_label=Lanyard") }

    patch settings_wallet_path
    follow_redirect!
    assert_select ".flash[role=alert]", text: /hasn't had the phrase yet/
    assert_not @alice.reload.wallet_connected?

    patch settings_wallet_path
    assert @alice.reload.wallet_connected?
    assert_not_includes @alice.read_attribute_before_type_cast(:link_session).to_s, "refresh-2", "kept encrypted"

    delete settings_wallet_path
    assert_requested(:post, "#{SIGN_IN}/device/revoke") { it.body.include?("token=refresh-2") }
    assert_nil @alice.reload.link_session
  end

  # Each finished sign-in is one more "Lanyard" under Apps and agents in
  # Link's app, and only the one this install keeps can be revoked from here.
  test "a wallet already connected is not connected again, from a page left open since or pressed twice" do
    stub_request(:post, "#{SIGN_IN}/device/code").to_return(json(device_code: "dev-2", user_code: "cherry-date", expires_in: 600,
      verification_uri: "https://app.link.com/device/setup"))
    stub_request(:post, "#{SIGN_IN}/device/token").to_return(json(access_token: "access-2", refresh_token: "refresh-2", expires_in: 3600))
    sign_in_as @alice

    post settings_wallet_path
    assert_not_requested :post, "#{SIGN_IN}/device/code"
    assert_equal "refresh-1", @alice.reload.link_session["refresh_token"], "the connection Link knows is the one kept"
    follow_redirect!
    assert_select ".flash", text: /already connected/

    patch settings_wallet_path
    assert_redirected_to settings_wallet_path
    assert_not_requested :post, "#{SIGN_IN}/device/token"
    assert_equal "refresh-1", @alice.reload.link_session["refresh_token"]
  end

  test "Start again after the phrase was entered at Link keeps that connection rather than making a second" do
    @alice.update!(link_session: { "device_code" => "dev-1", "phrase" => "apple-banana", "url" => "https://app.link.com/device/setup",
      "expires_at" => 10.minutes.from_now.to_i })
    stub_request(:post, "#{SIGN_IN}/device/code").to_return(json(device_code: "dev-2", user_code: "cherry-date", expires_in: 600,
      verification_uri: "https://app.link.com/device/setup"))
    stub_request(:post, "#{SIGN_IN}/device/token").to_return(json(access_token: "access-2", refresh_token: "refresh-2", expires_in: 3600))
    sign_in_as @alice

    post settings_wallet_path
    assert_not_requested :post, "#{SIGN_IN}/device/code"
    assert_equal "refresh-2", @alice.reload.link_session["refresh_token"]
    assert_requested(:post, "#{SIGN_IN}/device/token") { it.body.include?("device_code=dev-1") }
    follow_redirect!
    assert_select ".flash", text: /Connected/
  end

  test "Start again before the phrase was entered starts a new sign-in" do
    @alice.update!(link_session: { "device_code" => "dev-1", "phrase" => "apple-banana", "url" => "https://app.link.com/device/setup",
      "expires_at" => 10.minutes.from_now.to_i })
    stub_request(:post, "#{SIGN_IN}/device/code").to_return(json(device_code: "dev-2", user_code: "cherry-date", expires_in: 600,
      verification_uri: "https://app.link.com/device/setup"))
    stub_request(:post, "#{SIGN_IN}/device/token").to_return(json({ error: "authorization_pending" }, http: 400))
    sign_in_as @alice

    post settings_wallet_path
    follow_redirect!
    assert_select "#wallet_sign_in", text: /cherry-date/
    assert_equal "dev-2", @alice.reload.link_session["device_code"]
  end

  test "Start again after Link turned the phrase down starts a new sign-in, and Link out of reach drops nothing" do
    waiting = { "device_code" => "dev-1", "phrase" => "apple-banana", "url" => "https://app.link.com/device/setup",
      "expires_at" => 10.minutes.from_now.to_i }
    @alice.update!(link_session: waiting)
    stub_request(:post, "#{SIGN_IN}/device/code").to_return(json(device_code: "dev-2", user_code: "cherry-date", expires_in: 600,
      verification_uri: "https://app.link.com/device/setup"))
    stub_request(:post, "#{SIGN_IN}/device/token").to_return(json({ error: "access_denied" }, http: 400))
    sign_in_as @alice

    post settings_wallet_path
    assert_equal "dev-2", @alice.reload.link_session["device_code"]

    @alice.update!(link_session: waiting)
    stub_request(:post, "#{SIGN_IN}/device/token").to_timeout
    post settings_wallet_path
    follow_redirect!
    assert_select ".flash[role=alert]", text: /Couldn't reach Link/
    assert_equal "dev-1", @alice.reload.link_session["device_code"]
  end

  # Link is asked outside the lock, so a second tab can connect while this
  # one waits for Link's answer: the connection that loses is revoked at
  # Link, never kept as a second "Lanyard" there.
  test "a sign-in that finishes after another tab connected is revoked at Link, and the first connection kept" do
    @alice.update!(link_session: { "device_code" => "dev-1", "phrase" => "apple-banana", "url" => "https://app.link.com/device/setup",
      "expires_at" => 10.minutes.from_now.to_i })
    alice = @alice
    stub_request(:post, "#{SIGN_IN}/device/token").to_return do
      alice.class.find(alice.id).update!(link_session: { "access_token" => "access-other", "refresh_token" => "refresh-other",
        "expires_at" => 1.hour.from_now.to_i, "connected_at" => Time.current.to_i })
      json(access_token: "access-2", refresh_token: "refresh-2", expires_in: 3600)
    end
    revoke = stub_request(:post, "#{SIGN_IN}/device/revoke").with(body: hash_including("token" => "refresh-2")).to_return(json({}))
    sign_in_as @alice

    patch settings_wallet_path

    assert_requested revoke
    assert_equal "refresh-other", @alice.reload.link_session["refresh_token"]
  end

  test "approved in Link, the card reaches the sidecar once and nowhere else, and the charge settles it" do
    stub_link("pending_approval", "approved", "succeeded")
    log = capture_log do
      assert_equal "waiting", invoke["status"]
      payment = @conversation.invocations.sole.payment_request
      assert payment.requested?
      assert_enqueued_with(job: PaymentRequestJob, args: [ payment ])

      assert_equal PaymentRequest::ASK_EVERY, payment.advance
      created = @sent.sole
      assert_equal({ "amount" => 2450, "currency" => "usd", "merchant_name" => "Corner Books", "merchant_url" => "https://shop.example.com/checkout",
        "credential_type" => "card", "request_approval" => true, "test" => true }, created.except("idempotency_key", "context"))
      assert_operator created["context"].length, :>=, 100
      assert_match "Two paperbacks", created["context"]
      assert payment.reload.waiting?
      assert_in_delta 30.minutes.from_now, payment.expires_at, 5

      assert_equal PaymentRequest::ASK_EVERY, payment.advance, "still waiting for the person"
      assert_equal PaymentRequest::WATCH_EVERY, payment.advance
      assert payment.reload.approved?
      assert_equal [ "visa", "4242" ], [ payment.card_brand, payment.card_last4 ]
      assert @conversation.invocations.sole.approved?
      assert_nil @conversation.invocations.sole.approval, "approved in Link, not here"

      invoke
      perform_enqueued_jobs(only: InvocationCallJob)
      done = invoke
      assert_equal({ "status" => "done", "isError" => false, "pay" => true,
        "result" => { "paying" => "$24.50", "to" => "Corner Books", "card" => "Visa ending 4242", "site" => "shop.example.com" } }, done)

      post "/agent/cards", params: redeem, headers: rails_bearer, as: :json
      assert_response :ok
      assert_equal({ "number" => NUMBER, "cvc" => CVC, "exp_month" => 12, "exp_year" => 2030, "name" => "Alice Example",
        "postal_code" => "94110", "site" => "shop.example.com" }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]
      post "/agent/cards", params: redeem, headers: rails_bearer, as: :json
      assert_response :gone, "once only"

      assert_nil payment.advance, "charged"
      assert payment.reload.paid?
      [ payment.reload.attributes, @conversation.invocations.sole.attributes, invoke ].each { assert_not_includes it.to_json, NUMBER }
    end
    assert_match "Sidecar::CardsController#create", log, "the log was read"
    assert_not_includes log, NUMBER
    assert_not_includes log, CVC
  end

  test "it waits for Link even where the install approves everything, and is never offered Always" do
    stub_link
    with_setting(:app, :approve_everything, true) do
      with_setting(:app, :approvals, "allow") do
        assert_equal "waiting", invoke["status"]
      end
    end
    assert_empty @conversation.invocations.sole.always_choices
    assert_nil @conversation.invocations.sole.approval
  end

  # pay_by_card is looked up (Tool::Catalog::CORE, #116): through use_tool it
  # pays as it does called by its own name, from the same arguments.
  test "through use_tool it waits for Link the same way, for the same payment, and the card follows" do
    stub_link("pending_approval", "approved", "succeeded")
    assert_not @conversation.declares?("pay_by_card")
    used = ->(call_id = "toolu_u") do
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "use_tool", arguments: { "name" => "pay_by_card", "arguments" => ARGUMENTS },
        call_id: call_id), headers: rails_bearer, as: :json
      response.parsed_body
    end
    with_setting(:app, :approve_everything, true) { assert_equal "waiting", used.()["status"] }
    invocation = @conversation.invocations.sole
    assert_equal :payment, invocation.asks
    assert_empty invocation.always_choices
    payment = invocation.payment_request
    assert_equal [ 2450, "usd", "Corner Books", "https://shop.example.com/checkout" ], payment.values_at(:amount, :currency, :payee, :checkout_url)
    html = Nokogiri::HTML5.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
    assert html.at_css(".payment"), "its card is the payment's, as a direct call's is, not a generic approval"

    3.times { payment.advance }
    assert invocation.reload.approved?
    used.()
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal true, used.()["pay"], "the sidecar types the card in after it, as for a direct call"
  end

  # Needs you, and the card the phone and the Watch read, show the payment as
  # its own card does, never the amount in cents the agent passed (#263).
  test "Needs you shows the amount and the payee, called directly or through use_tool" do
    stub_link
    invoke
    post "/agent/invocations", params: invocation_payload(@conversation, tool: "use_tool",
      arguments: { "name" => "pay_by_card", "arguments" => ARGUMENTS }, call_id: "toolu_u"), headers: rails_bearer, as: :json
    assert_equal "waiting", response.parsed_body["status"]
    invocations = @conversation.invocations.order(:id)
    assert_equal %w[ pay_by_card use_tool ], invocations.map(&:tool_name)

    sign_in_as @alice
    get approvals_path
    invocations.each do |invocation|
      assert_equal "Approve a payment in Link? · $24.50 to Corner Books",
        css_select("##{ActionView::RecordIdentifier.dom_id(invocation, :waiting)} .conversation-row__preview").text, invocation.tool_name
      fields = Invocation::Card.new(invocation).as_json[:fields]
      assert_equal [ "$24.50 to Corner Books", "shop.example.com", ARGUMENTS["reason"] ], fields.pluck(:text), invocation.tool_name
    end
  end

  test "the card says where it stands in each state, and offers Cancel only while it is open" do
    stub_link
    invoke
    invocation = @conversation.invocations.sole
    payment = invocation.payment_request
    payment.update!(link_id: "lsrq_1", approval_url: "https://app.link.com/approve/lsrq_1", expires_at: 30.minutes.from_now)
    {
      "requested" => [ "Approve $24.50 to Corner Books in Link", "Sending it to Link", [ "Cancel" ] ],
      "waiting" => [ "Approve $24.50 to Corner Books in Link", "Approve it in the Link app on your phone by", [ "Open in Link", "Cancel" ] ],
      "approved" => [ "Approved: $24.50 to Corner Books", "A one-time card for this amount", [ "Cancel the card" ] ],
      "paid" => [ "Paid $24.50 to Corner Books", "Charged once", [] ],
      "declined" => [ "Payment declined", "You declined it in Link", [] ],
      "expired" => [ "Payment expired", "wasn't approved within 30 minutes", [] ],
      "canceled" => [ "Payment cancelled", "Cancelled by Alice", [] ],
      "failed" => [ "Payment failed", "Link refused it (card_declined). The card is closed at Link.", [] ]
    }.each do |state, (title, status, buttons)|
      payment.update_columns(state: state, decided_by: "Alice", failure: "Link refused it (card_declined)",
        card_brand: "visa", card_last4: ("4242" if state.in?(%w[ approved failed ])), card_valid_until: 12.hours.from_now)
      html = Nokogiri::HTML5.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation.reload }))
      assert_equal title, html.at_css(".payment .ui-card__title").text, state
      assert_includes html.at_css(".payment__status").text.squish, status, state
      assert_equal buttons, html.css(".payment a.button, .payment button").map { it.text.strip }, state
      assert_nil html.at_css("[value=approve]"), "never approved here (#{state})"
      # Its confirm's Cancel doesn't read like "Cancel the card".
      assert_equal "Keep the card", html.at_css("button[data-confirm-dismiss]")["data-confirm-dismiss"] if state == "approved"
    end
  end

  test "not approved within Link's 30 minutes, it is closed at Link and the call says nothing was paid" do
    stub_link("pending_approval")
    invoke
    payment = @conversation.invocations.sole.payment_request
    payment.advance
    travel 31.minutes do
      assert_nil payment.advance
    end
    assert payment.reload.expired?
    assert_requested :post, "#{API}/spend_requests/lsrq_1/cancel"
    assert @conversation.invocations.sole.failed?
    assert_match "within 30 minutes", @conversation.invocations.sole.error
  end

  test "declined in Link, the call is declined" do
    stub_link("denied")
    invoke
    payment = @conversation.invocations.sole.payment_request
    2.times { payment.advance }
    assert payment.reload.declined?
    assert @conversation.invocations.sole.denied?
  end

  test "the person cancels before Link's answer, or an approved card before it is used, and Link closes it first" do
    stub_link("pending_approval")
    sign_in_as @alice
    invoke
    payment = @conversation.invocations.sole.payment_request
    payment.advance
    delete conversation_invocation_payment_path(@conversation, @conversation.invocations.sole)
    assert payment.reload.canceled?
    assert_equal "Alice", payment.decided_by
    assert @conversation.invocations.sole.denied?
    assert_requested :post, "#{API}/spend_requests/lsrq_1/cancel"

    stub_link("approved", id: "lsrq_2")
    invoke(call_id: "toolu_2")
    approved = PaymentRequest.where.not(id: payment.id).sole
    2.times { approved.advance }
    assert approved.reload.approved?
    delete conversation_invocation_payment_path(@conversation, approved.invocation)
    assert approved.reload.canceled?
    invoke(call_id: "toolu_2")
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_match "isn't approved in Link", invoke(call_id: "toolu_2")["result"].to_s
    post "/agent/cards", params: redeem(call_id: "toolu_2"), headers: rails_bearer, as: :json
    assert_response :gone
  end

  test "cancelled while it is being sent, the request Link just made is closed too" do
    stub_link("pending_approval")
    invoke
    payment = @conversation.invocations.sole.payment_request
    PaymentRequest.find(payment.id).cancel!(by: @alice)
    assert_nil payment.advance
    assert payment.reload.canceled?
    assert_nil payment.link_id
    assert_requested :post, "#{API}/spend_requests/lsrq_1/cancel"
  end

  test "a card cancelled after the call ran can no longer be collected" do
    stub_link("approved")
    invoke
    payment = @conversation.invocations.sole.payment_request
    2.times { payment.advance }
    invoke
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal "done", invoke["status"]
    payment.reload.cancel!(by: @alice)
    post "/agent/cards", params: redeem, headers: rails_bearer, as: :json
    assert_response :gone
    assert_not_requested :get, "#{API}/spend_requests/lsrq_1?include=card"
  end

  test "a cancel that lands while the job asks Link is not undone by Link's approval" do
    stub_link("approved")
    invoke
    payment = @conversation.invocations.sole.payment_request
    payment.advance
    PaymentRequest.find(payment.id).cancel!(by: @alice)
    assert_nil payment.advance
    assert payment.reload.canceled?
    assert @conversation.invocations.sole.denied?
  end

  test "a failed charge, or a card left unused, is closed at Link" do
    stub_link("approved", { "status" => "approved", "payment_status_details" => { "outcome" => "failure", "decline_code" => "insufficient_funds" } })
    invoke
    payment = @conversation.invocations.sole.payment_request
    3.times { payment.advance }
    assert payment.reload.failed?
    assert_equal "The charge was declined (insufficient_funds)", payment.failure
    assert_requested :post, "#{API}/spend_requests/lsrq_1/cancel"

    stub_link("approved", "approved", id: "lsrq_2")
    invoke(call_id: "toolu_2")
    unused = PaymentRequest.where.not(id: payment.id).sole
    2.times { unused.advance }
    travel PaymentRequest::CARD_LASTS + 1.minute do
      assert_nil unused.advance
    end
    assert unused.reload.expired?
    assert_requested :post, "#{API}/spend_requests/lsrq_2/cancel"
  end

  test "Link refusing the request fails the call, and its answer's body is never repeated" do
    stub_request(:post, "#{API}/spend_requests").to_return(json({ error: { code: "amount_too_large", message: "Too much" }, card: { number: NUMBER } }, http: 400))
    invoke
    payment = @conversation.invocations.sole.payment_request
    assert_nil payment.advance
    assert payment.reload.failed?
    assert_equal "Link refused the request: Link answered HTTP 400 (amount_too_large): Too much", payment.failure
    assert @conversation.invocations.sole.failed?
    assert_not_includes @conversation.invocations.sole.error, NUMBER
  end

  test "disconnecting the wallet cancels an open payment at Link first" do
    stub_link("pending_approval")
    stub_request(:post, "#{SIGN_IN}/device/revoke").to_return(json({}))
    invoke
    payment = @conversation.invocations.sole.payment_request
    payment.advance
    @alice.disconnect_wallet!
    assert payment.reload.canceled?
    assert_requested :post, "#{API}/spend_requests/lsrq_1/cancel"
    assert_not @alice.reload.wallet_connected?
  end

  test "the job asks again while it waits, a second job for it does nothing, and it stops when it is settled" do
    stub_link("pending_approval")
    invoke
    payment = @conversation.invocations.sole.payment_request
    clear_enqueued_jobs
    PaymentRequestJob.perform_now(payment)
    assert_enqueued_with(job: PaymentRequestJob, args: [ payment ])
    assert_in_delta PaymentRequest::ASK_EVERY.from_now, payment.reload.next_ask_at, 1

    clear_enqueued_jobs
    PaymentRequestJob.perform_now(payment)
    assert_no_enqueued_jobs only: PaymentRequestJob
    assert_requested :get, "#{API}/spend_requests/lsrq_1", times: 0

    travel PaymentRequest::ASK_EVERY + 1.second
    payment.update!(state: :paid)
    PaymentRequestJob.perform_now(payment)
    assert_no_enqueued_jobs only: PaymentRequestJob
    assert_nil payment.reload.next_ask_at
  end

  test "a payment whose job was lost is picked up again, and one whose job is alive is left alone" do
    stub_link("pending_approval")
    invoke
    lost = @conversation.invocations.sole.payment_request
    invoke(call_id: "toolu_2")
    alive = PaymentRequest.where.not(id: lost.id).sole
    alive.update_column(:next_ask_at, 3.seconds.from_now)

    travel PaymentRequest::OVERDUE + 1.minute do
      alive.update_column(:next_ask_at, 3.seconds.from_now)
      clear_enqueued_jobs
      PaymentRequestSweepJob.perform_now
      assert_enqueued_jobs 1, only: PaymentRequestJob
      assert_enqueued_with(job: PaymentRequestJob, args: [ lost ])
    end
  end

  test "an access token about to run out is renewed first" do
    @alice.update!(link_session: @alice.link_session.merge("expires_at" => 10.seconds.from_now.to_i))
    stub_request(:post, "#{SIGN_IN}/device/token").to_return(json(access_token: "access-3", refresh_token: "refresh-3", expires_in: 3600))
    assert_equal "access-3", @alice.wallet_token
    assert_requested(:post, "#{SIGN_IN}/device/token") { it.body.include?("grant_type=refresh_token") && it.body.include?("refresh_token=refresh-1") }
  end

  private
    def sign_in_as(user) = sign_in_via_ajent(subject: user.oidc_sub, email: "operator@example.com", name: user.name)

    def invoke(call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "pay_by_card", arguments: ARGUMENTS, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    def redeem(call_id: "toolu_1")
      invocation_payload(@conversation, tool: "pay_by_card", arguments: ARGUMENTS, call_id: call_id).slice(:actorId, :workspaceId, :conversationId, :taskId, :callId)
    end

    def json(body = nil, http: 200, **fields) = { status: http, body: (body || fields).to_json, headers: { "Content-Type" => "application/json" } }

    # Link's request (lsrq_1 for the first made, and so on), answering each
    # look with the next status or whole answer, the last one from then on.
    def stub_link(*answers, id: "lsrq_1")
      looks = answers.map { it.is_a?(Hash) ? it : { "status" => it } }
        .map { json({ id: id, card_brand: "visa", card_last4: "4242" }.merge(it)) }
      stub_request(:get, "#{API}/spend_requests/#{id}").to_return(*looks) if looks.any?
      stub_request(:get, "#{API}/spend_requests/#{id}?include=card").to_return(json(id: id, status: "approved",
        card: { id: "card_1", brand: "visa", number: NUMBER, cvc: CVC, exp_month: 12, exp_year: 2030,
          billing_address: { name: "Alice Example", postal_code: "94110", country: "US", line1: "1 Example St" } }))
      stub_request(:post, "#{API}/spend_requests/#{id}/cancel").to_return(json(id: id, status: "canceled"))
    end

    def capture_log
      output = StringIO.new
      logger = ActiveSupport::Logger.new(output)
      Rails.logger.broadcast_to(logger)
      yield
      output.string
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end
end
