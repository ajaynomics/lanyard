require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# The real miss (#251): an agent put up a replacement send card while its
# first one was still waiting. The person allowed both, and the recipient got
# two near-identical emails. An agent now takes back a card it has replaced
# (withdraw_card), and a withdrawn card can never be allowed afterwards: an
# approval arriving later, from a page the person left open, the phone or the
# Watch, is refused under the same lock a decision takes, and nothing is sent.
class WithdrawnCardsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  FIRST = { "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Two nights, arriving at six." }.freeze
  SECOND = FIRST.merge("body" => "Two nights, arriving at eight.").freeze
  # What a decision sets going: the ring, the call itself, and what the agent
  # is told. Not the background check of a send whose server went quiet, which
  # reschedules itself and so never ends inside perform_enqueued_jobs.
  DECIDING = [ InvocationWakeJob, InvocationCallJob, InvocationReportJob ].freeze
  LINK = DurableAssistants::Link::API
  PAYMENT = { "amount" => 2450, "currency" => "usd", "payee" => "Corner Books", "checkout_url" => "https://shop.example.com/checkout",
    "reason" => "Two paperbacks the person asked for this morning." }.freeze

  setup do
    install_sidecar_settings
    install_email_settings
    ActionMailer::Base.deliveries.clear
    sign_in_via_ajent
    @person = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @person.agents.sole
    @conversation = create_conversation(@agent)
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12\?}).to_return(body: { status: "done", failure: nil, pendingInputs: [], queued: [] }.to_json)
    @wakes = stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
  end

  teardown do
    Rails.application.config.x.link = @previous_link if @previous_link
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  # The case itself.
  test "the agent withdraws the card it replaced, and only the second send goes" do
    first = send_card(FIRST, "toolu_1")
    second = send_card(SECOND, "toolu_2")
    assert first.answerable?, "both cards wait on the person"
    assert second.answerable?

    withdrawal = invoke("withdraw_card", { "card_id" => first.id }, call_id: "toolu_w")
    perform_enqueued_jobs(only: DECIDING) { post conversation_invocation_approval_path(@conversation, first), params: { decision: "approve" } }
    perform_enqueued_jobs(only: DECIDING) { post conversation_invocation_approval_path(@conversation, second), params: { decision: "approve" } }

    assert_equal 1, ActionMailer::Base.deliveries.size, "the withdrawn card sends nothing: one email, not two"
    assert_match "arriving at eight", ActionMailer::Base.deliveries.sole.text_part.decoded, "the one the person allowed last"
    assert_equal({ "status" => "done", "result" => { "withdrawn" => first.id }, "isError" => false }, withdrawal)
    assert first.reload.withdrawn?
    assert_nil first.approval, "a withdrawn card records no decision"
    assert_not_includes Invocation.waiting_on_person, first
    assert second.reload.succeeded?
  end

  test "an approval posted from a page left open, and from the phone, is refused and sends nothing" do
    card = send_card(FIRST, "toolu_1")
    stale = Invocation::Card.new(card).version # what the open page and the Watch showed
    invoke("withdraw_card", { "card_id" => card.id }, call_id: "toolu_w")

    perform_enqueued_jobs(only: DECIDING) { post conversation_invocation_approval_path(@conversation, card), params: { decision: "approve" } }
    assert_redirected_to conversation_path(@conversation)
    assert_equal "That request has already been answered or has expired.", flash[:alert]

    perform_enqueued_jobs(only: DECIDING) do
      post conversation_invocation_approval_path(@conversation, card), params: { decision: "approve", version: stale }, as: :json
    end
    assert_response :conflict
    assert_equal "answered_or_expired", response.parsed_body["error"]

    perform_enqueued_jobs(only: DECIDING) { post conversation_invocation_approval_path(@conversation, card), params: { decision: "deny" } }
    assert_equal "That request has already been answered or has expired.", flash[:alert]

    assert card.reload.withdrawn?, "withdrawn it stays"
    assert_nil card.approval
    assert_empty ActionMailer::Base.deliveries
    assert_no_enqueued_jobs only: InvocationCallJob
  end

  test "only its own waiting approval cards: another agent's, a question, and one already settled are refused" do
    mine = send_card(FIRST, "toolu_1")
    other_agent = create_conversation(@agent, durable_id: "34")
    theirs = send_card(FIRST, "toolu_o", conversation: other_agent)

    refused = invoke("withdraw_card", { "card_id" => theirs.id }, call_id: "toolu_w1")
    assert refused["isError"], "another agent's card is not this agent's to take back"
    assert theirs.reload.answerable?

    question = send_question("toolu_q")
    assert invoke("withdraw_card", { "card_id" => question.id }, call_id: "toolu_w2")["isError"], "a question is withdrawn with withdraw_question"
    assert question.reload.answerable?

    approved = send_card(SECOND, "toolu_a")
    approved.approve!(by: @person)
    assert invoke("withdraw_card", { "card_id" => approved.id }, call_id: "toolu_w3")["isError"], "already allowed"

    denied = send_card(FIRST.merge("subject" => "Saturday"), "toolu_d")
    denied.deny!(by: @person)
    assert invoke("withdraw_card", { "card_id" => denied.id }, call_id: "toolu_w4")["isError"], "already declined"

    expired = send_card(FIRST.merge("subject" => "Sunday"), "toolu_e")
    expired.update!(expires_at: 1.minute.ago)
    assert invoke("withdraw_card", { "card_id" => expired.id }, call_id: "toolu_w5")["isError"], "expired"

    assert invoke("withdraw_card", { "card_id" => mine.id + 10_000 }, call_id: "toolu_w6")["isError"], "no such card"

    assert_equal({ "withdrawn" => mine.id }, invoke("withdraw_card", { "card_id" => mine.id }, call_id: "toolu_w7")["result"])
    assert invoke("withdraw_card", { "card_id" => mine.id }, call_id: "toolu_w8")["isError"], "a second withdrawal is refused"
  end

  test "a withdrawn card reads Withdrawn in the thread, with nothing left to allow" do
    card = send_card(FIRST, "toolu_1")
    invoke("withdraw_card", { "card_id" => card.id }, call_id: "toolu_w")

    assert_equal "Withdrawn", card.reload.error_label
    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "toolu_1", "name" => "send_email" } ])
    get conversation_path(@conversation)
    assert_select "##{card.dom_target} .ui-trace__title", "Withdrew send email"
    assert_select "##{card.dom_target} .ui-trace:not([data-status])", 1, "withdrawn is a normal outcome, not the error dot"
    assert_equal [ "Input", "Withdrawn" ], css_select("##{card.dom_target} .ui-code__label").map(&:text)
    assert_select "##{card.dom_target} form[action=?]", conversation_invocation_approval_path(@conversation, card), count: 0
    assert_select ".needs-you a[href=?]", approval_path(card), count: 0

    get approvals_path
    assert_select "#approvals a[href=?]", approval_path(card), count: 0
  end

  test "the handed-back answer names the card, so the agent can take it back" do
    assert_equal "waiting", invoke("send_email", FIRST, call_id: "toolu_1")["status"]
    card = @conversation.invocations.sole
    handed = invoke("send_email", FIRST, call_id: "toolu_1", hand_back: true)

    assert_equal({ "status" => "handedBack", "key" => card.wait_key, "card" => card.id }, handed)
    assert_equal handed, invoke("send_email", FIRST, call_id: "toolu_1"), "a replay after a crash names it too"
  end

  test "withdraw_card is looked up, not declared, so no agent declares a tool more" do
    assert_includes @conversation.lookup_tools.map(&:tool_name), "withdraw_card"
    assert_not @conversation.declares?("withdraw_card")
    assert_not_includes Tool::Catalog::CORE, "withdraw_card"
    assert_includes @agent.own_tools.map(&:tool_name), "withdraw_card", "every agent may be asked to allow a call"
    assert_operator @agent.tool_count, :<=, Agent::TOOL_LIMIT
  end

  test "withdrawing asks no one: it only ever takes a pending action away" do
    assert_nil Tool::WithdrawCard.asks
    card = send_card(FIRST, "toolu_1")

    with_setting(:app, :approve_everything, true) do
      assert_equal({ "withdrawn" => card.id }, invoke("withdraw_card", { "card_id" => card.id }, call_id: "toolu_w")["result"])
    end
    assert card.reload.withdrawn?
    assert_empty ActionMailer::Base.deliveries
  end

  # The two cards an agent raises that are settled where they are answered,
  # not by the thread's approval form: a payment the person approves in Link's
  # app, and a sign-in they type into their own form. Neither is `asks
  # :approval`, so neither is an approval card of the agent's own to take back,
  # even from a call of its own. Each stays answerable and still takes its own
  # answer afterwards.
  test "a payment card and a sign-in card of the agent's own are refused, and stay answerable" do
    install_sign_ins
    payment = payment_card("toolu_p")
    sign_in = sign_in_card("toolu_s")
    assert_equal [ :payment, :sign_in ], [ payment.asks, sign_in.asks ], "neither asks :approval"

    refused = invoke("withdraw_card", { "card_id" => payment.id }, call_id: "toolu_w1")
    assert refused["isError"], "a payment is approved in Link, never taken back here"
    assert_match "waiting on a call of your own", refused["result"].to_s
    assert invoke("withdraw_card", { "card_id" => sign_in.id }, call_id: "toolu_w2")["isError"],
      "a sign-in is typed into the person's own form"

    assert_equal %w[ awaiting_person awaiting_person ], [ payment.reload.state, sign_in.reload.state ], "nothing changed state"
    assert payment.answerable?
    assert sign_in.answerable?
    assert_not payment.withdrawn?
    assert_not sign_in.withdrawn?

    2.times { payment.payment_request.advance }
    assert payment.reload.approved?, "the payment still takes Link's answer"

    post conversation_invocation_sign_in_path(@conversation, sign_in), params: { sign_in: { username: "maya", password: PassboltTestHelper::PASSWORD } }
    assert sign_in.reload.approved?, "the sign-in still takes the person's own form"
  end

  # ask_outside_for_sign_in is an ordinary approval card (asks :approval), not
  # a :sign_in one: it is allowed on the thread's own approval form like any
  # other, so the agent may take it back. Its link is issued only once the
  # person allows it, so a withdrawn one leaves nothing behind.
  test "a card asking to let someone outside fill a sign-in is an ordinary approval, withdrawn like one" do
    install_sign_ins
    assert_equal "waiting", invoke("ask_outside_for_sign_in", { "name" => "Bank" }, call_id: "toolu_o")["status"]
    card = @conversation.invocations.find_by!(call_id: "toolu_o")
    assert_equal :approval, card.asks

    assert_equal({ "withdrawn" => card.id }, invoke("withdraw_card", { "card_id" => card.id }, call_id: "toolu_w")["result"])
    assert card.reload.withdrawn?
    assert_empty @conversation.sign_in_links, "no link is issued until the person allows it"
  end

  private
    def invoke(tool, arguments, call_id:, hand_back: false)
      payload = invocation_payload(@conversation.reload, tool: tool, arguments: arguments, call_id: call_id)
      post "/agent/invocations", params: hand_back ? payload.merge(handBack: true) : payload, headers: rails_bearer, as: :json
      response.parsed_body
    end

    # A send waiting on the person, its card handed back as the agent's own
    # call's is while messages wait, which is how two came to wait at once.
    def send_card(arguments, call_id, conversation: @conversation)
      conversation.reload
      payload = invocation_payload(conversation, tool: "send_email", arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: "send_email", arguments: arguments,
        digest: payload[:digest], hand_back: true)
      conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "#{call_id} should wait for the person" }
    end

    def send_question(call_id)
      arguments = { "question" => "Which day suits the visit?", "wait" => false }
      payload = invocation_payload(@conversation.reload, tool: "ask_person", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "ask_person", arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: call_id)
    end

    # A payment waiting on the person in Link's app (Tool::PayByCard), from a
    # call of the agent's own. Link is a stand-in at the HTTP boundary.
    def payment_card(call_id)
      @previous_link = Rails.application.config.x.link
      Rails.application.config.x.link = { client_id: "lwlpk_example", client_name: "Lanyard", test_mode: true }
      @person.update!(link_session: { "access_token" => "access-1", "refresh_token" => "refresh-1",
        "expires_at" => 2.days.from_now.to_i, "connected_at" => Time.current.to_i })
      @agent.update!(tool_names: @agent.tool_names | [ "pay_by_card" ])
      looked = { id: "lsrq_1", card_brand: "visa", card_last4: "4242" }
      stub_request(:post, "#{LINK}/spend_requests").to_return(link_answer(looked.merge(status: "pending_approval",
        approval_url: "https://app.link.com/approve/lsrq_1")))
      stub_request(:get, "#{LINK}/spend_requests/lsrq_1").to_return(link_answer(looked.merge(status: "approved")))
      stub_request(:post, "#{LINK}/spend_requests/lsrq_1/cancel").to_return(link_answer(looked.merge(status: "canceled")))
      invoke("pay_by_card", PAYMENT, call_id: call_id)
      @conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "the payment should wait on the person" }
    end

    def link_answer(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

    # Every agent with a screen has the sign-in tools where the install has a
    # password manager (Tool::Catalog::SAVED_SIGN_INS); the empty entry is the
    # one an outsider may fill.
    def install_sign_ins
      @agent.create_computer!(provider: "sprites", state: "on")
      install_fake_passbolt(password: "")
      @conversation.reload
    end

    # A sign-in the person types into their own form (Tool::AskForSignIn).
    def sign_in_card(call_id)
      arguments = { "name" => "Library", "site" => "https://library.example/login" }
      payload = invocation_payload(@conversation.reload, tool: "ask_for_sign_in", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "ask_for_sign_in",
        arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "the sign-in should wait on the person" }
    end
end
