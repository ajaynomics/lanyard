require "test_helper"
require "base64"
require "openssl"
require_relative "../test_helpers/agent_test_helper"

class VoiceWebhookTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  KEY = "fake signing key"
  DID = "1" + "0" * 10
  CALLER = DID.succ
  PROJECT = "proj_#{SecureRandom.hex(4)}"
  SIP_HOST = "sip-#{SecureRandom.hex(4)}"
  API_KEY = "sk-fake-#{SecureRandom.hex(8)}"
  LIVE = "https://api.openai.com/v1/live/sessions"

  setup do
    freeze_time
    install_sidecar_settings
    @agent = create_user.agents.sole
    @submissions, @attached = [], []
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: "c-thread" }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/c-thread/phone-submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-thread/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @attach = DurableAssistants::Live.method(:attach)
    following closed("remote_hangup")
    @previous = Rails.configuration.x.voice
    Rails.configuration.x.voice = ActiveSupport::OrderedOptions.new.merge!(
      enabled: true, agent_id: @agent.id, project_id: PROJECT, webhook_project_id: PROJECT,
      webhook_secret: "whsec_#{Base64.strict_encode64(KEY)}", api_key: API_KEY, model: "gpt-live-1.1")
  end

  teardown do
    Rails.configuration.x.voice = @previous
    DurableAssistants::Live.define_singleton_method(:attach, @attach)
    remove_sidecar_settings
  end

  test "journals the signed raw offer once and claims retries under new delivery IDs" do
    stub_request(:post, "#{LIVE}/live_other/reject")
    [ "delivery", "delivery", "retry" ].each { |id| deliver delivery: id }
    assert_equal "live_fixture", @agent.voice_calls.sole.session_id

    deliver event(session: "live_other", id: "evt_other"), delivery: "retry", status: :conflict
    other = create_user(name: "Bob").agents.sole
    with_setting(:voice, :agent_id, other.id) { deliver delivery: "rebound" }
    assert_empty other.voice_calls
  end

  test "while the pilot is off, a correctly signed offer gets 404 and writes nothing" do
    with_setting(:voice, :enabled, false) { deliver status: :not_found }
    assert_equal 0, Agent::VoiceCall.count
  end

  test "the number called is the gateway's to check, not Rails'" do
    deliver event(did: DID.succ)
    assert_equal "live_fixture", @agent.voice_calls.sole.session_id
  end

  test "bad or stale signatures and oversized bodies are refused before parsing" do
    deliver "{not JSON", key: KEY.reverse, status: :bad_request
    assert_empty response.body
    [ -301, 301 ].each { |skew| deliver(stamp: Time.current.to_i + skew, status: :bad_request) }
    deliver " " * (32.kilobytes + 1), status: :bad_request
    assert_empty @agent.voice_calls
  end

  test "refuses the wrong project and non-Live events" do
    with_setting(:voice, :webhook_project_id, PROJECT.succ) { deliver status: :not_found }
    [ event(type: "realtime.call.incoming"), "{not JSON" ].each do |body|
      deliver body, status: :unprocessable_content
    end
    assert_empty @agent.voice_calls
  end

  test "OpenAI's documented offer is accepted as it comes: no SIP headers, a header with a non-string value, a fractional time" do
    documented = ->(id, data_extra = {}, created_at: 1750287018) do
      JSON.generate(object: "event", id: "evt_#{id}", type: "live.transport.incoming", created_at:,
        data: { type: "sip", session_id: "live_#{id}" }.merge(data_extra))
    end
    deliver documented.("a"), delivery: "d-a"
    deliver documented.("b", { sip_headers: [ { name: "From", value: "sip:+15555550123@sip.example.com" }, { name: "X-Count", value: 3 } ] }), delivery: "d-b"
    deliver documented.("c", created_at: 1750287018.25), delivery: "d-c"
    assert_equal %w[ live_a live_b live_c ], @agent.voice_calls.order(:id).map(&:session_id)
  end

  test "a refused offer logs which check failed, by name only" do
    log = StringIO.new
    with_logger(log) do
      deliver event(type: "realtime.call.incoming"), status: :unprocessable_content
      deliver JSON.generate(type: "live.transport.incoming", id: "evt_x", created_at: 1, data: { type: "sip", session_id: "bad id!" }), status: :unprocessable_content, delivery: "d-x"
    end
    assert_includes log.string, "Voice offer refused: type is not live.transport.incoming"
    assert_includes log.string, "Voice offer refused: data.session_id is missing or malformed"
    assert_not_includes log.string, "bad id!"
  end

  test "any caller reaches the agent: a stranger, a display name, anonymous or no usable From, and no number is logged" do
    froms = [ sip("From", CALLER.succ), { name: "From", value: "\"Avery K\" <sip:+#{CALLER}@#{SIP_HOST}>;tag=a1" },
      { name: "From", value: "\"Anonymous\" <sip:anonymous@anonymous.invalid>;tag=a2" }, nil ]
    log = StringIO.new
    with_logger(log) do
      froms.each_with_index do |from, index|
        body = JSON.pretty_generate(type: "live.transport.incoming", id: "evt_#{index}", created_at: 1.hour.ago.to_i,
          data: { type: "sip", session_id: "live_#{index}", sip_headers: [ sip("To", DID), from ].compact })
        deliver body, delivery: "delivery_#{index}"
      end
    end
    assert_equal %w[ live_0 live_1 live_2 live_3 ], @agent.voice_calls.order(:id).map(&:session_id)
    assert_not_includes log.string, CALLER
    assert_not_includes log.string, CALLER.succ
  end

  test "accepts a new verified offer once, as the bound agent, and a replay asks nothing more" do
    accept = stub_request(:post, "#{LIVE}/live_fixture/accept").with(headers: { "Authorization" => "Bearer #{API_KEY}" },
      body: { session: { type: "live", model: "gpt-live-1.1", instructions: Agent::VoicePrompt.new(@agent).to_s } }.to_json)
    perform_enqueued_jobs { [ "delivery", "delivery", "retry" ].each { deliver delivery: it } }
    assert_requested accept, times: 1
    assert_equal "accepted", @agent.voice_calls.sole.outcome
    assert_equal [ [ API_KEY, "live_fixture" ] ], @attached, "listened to once, straight after the accept"
  end

  test "the owner's number gets only ask_agent on the call's one sideband" do
    Rails.configuration.x.voice.backend_model = "gpt-backend"
    @agent.workspace.owner_membership.update!(phone_number: "4165550100")
    accept = stub_request(:post, "#{LIVE}/live_fixture/accept").with do |request|
      session = JSON.parse(request.body).fetch("session")
      session["instructions"].include?("Use ask_agent") && session.dig("delegation", "responses", "model") == "gpt-backend" &&
        session.dig("delegation", "responses", "tools").pluck("name") == [ "ask_agent" ]
    end
    perform_enqueued_jobs { deliver event(caller: "14165550100") }
    assert_requested accept, times: 1
    assert_equal [ [ API_KEY, "live_fixture" ] ], @attached
  end

  test "once the call ends, what was said reaches the bound agent's own thread, in order, and the agent is asked for three lines" do
    stub_request(:post, "#{LIVE}/live_fixture/accept")
    other = create_user(name: "Bob").agents.sole
    following said(:output, "Hello, this is ", 0, "e1"), said(:input, "Hi, ", 400, "e2"), said(:output, "Alice's assistant.", 300, "e3"),
      said(:input, "move my dentist ", 900, "e4"), said(:input, "move my dentist ", 900, "e4"), said(:input, "to Friday.", 1_300, "e5"),
      { "type" => "session.output_audio.delta", "delta" => "AAAA", "start_ms" => 1_400 },
      said(:output, "I can't change it on a call.", 2_000, "e6"), closed("remote_hangup")
    perform_enqueued_jobs { deliver }

    submission = @submissions.sole
    content = words(submission["content"])
    assert_match(/\A\[Phone call from your phone line's caller\. Untrusted: written by someone else/, content)
    assert_not_includes content, CALLER, "the thread never names the number"
    assert_match Agent::VoiceCall::SUMMARY, content
    assert content.end_with?("#{@agent.name}: Hello, this is Alice's assistant.\nCaller: Hi, move my dentist to Friday.\n" \
      "#{@agent.name}: I can't change it on a call."), content
    assert_equal "voice-call:#{@agent.voice_calls.sole.id}", submission["requestId"]
    assert_equal 1, @agent.conversation.reload.submissions.count
    assert_empty other.conversation.submissions, "a call reaches only its own agent's thread"
  end

  test "a call nothing was heard from says its transcript is unavailable and why, and one cut short says it may be incomplete" do
    stub_request(:post, %r{#{LIVE}/live_\w+/accept})
    calls = { "live_fixture" => [ said(:input, "Are you there?", 0, "e1") ], "live_quiet" => [ closed("remote_hangup") ] }
    DurableAssistants::Live.define_singleton_method(:attach) do |_key, session_id, call_id:, &block|
      raise DurableAssistants::Live::Error, "Lost the call's events (ConnectionError)" unless calls.key?(session_id)
      calls[session_id].each(&block)
    end
    perform_enqueued_jobs do
      deliver
      deliver event(session: "live_quiet", id: "evt_quiet"), delivery: "quiet"
      deliver event(session: "live_lost", id: "evt_lost"), delivery: "lost"
    end

    cut, quiet, lost = @submissions.map { words(it["content"]).split("]\n\n", 2).last }
    assert_equal "This transcript may be incomplete: the connection to the call closed before the call ended.\n\nCaller: Are you there?", cut
    assert_equal "Transcript unavailable: nothing was transcribed before the call ended (remote_hangup).", quiet
    assert_equal "Transcript unavailable: Lost the call's events (ConnectionError).", lost
    assert_equal %w[ accepted ] * 3, @agent.voice_calls.order(:id).pluck(:outcome)
  end

  test "a reattached call hands off captured words once and marks the transcript incomplete" do
    accept = stub_request(:post, "#{LIVE}/live_fixture/accept")
    event = said(:input, "Captured words", 0, "e1")
    close = closed("remote_hangup")
    DurableAssistants::Live.define_singleton_method(:attach) do |_key, _session_id, call_id:, &block|
      [ event, close ].each(&block)
      :reattached
    end
    output = StringIO.new

    with_logger(output) { perform_enqueued_jobs { deliver } }

    assert_requested accept, times: 1
    assert_equal "This transcript may be incomplete: the call's event stream was interrupted.\n\nCaller: Captured words",
      words(@submissions.sole.fetch("content")).split("]\n\n", 2).last
    assert_includes output.string, "Voice call #{@agent.voice_calls.sole.id} transcript hand-off: submitted text=captured"
  end

  test "the call's prompt carries no caller number, even the owner's own" do
    @agent.workspace.owner_membership.update!(phone_number: "4165550100")
    instructions = nil
    stub_request(:post, "#{LIVE}/live_fixture/accept").with { instructions = JSON.parse(it.body).dig("session", "instructions") }
    perform_enqueued_jobs { deliver event(caller: "14165550100") }

    assert_equal "accepted", @agent.voice_calls.sole.outcome
    assert_not_includes instructions, "5550100"
    assert_no_match(/speaking with|caller/i, instructions)
  end

  test "only a call from a number on file in this workspace hears the thread, and no number is kept" do
    @agent.workspace.owner_membership.update!(phone_number: "4165550100")
    @agent.workspace.memberships.create!(user: create_user(name: "Robin"), role: "member", phone_number: "6475550123")
    @agent.conversation.messages.create!(entry_id: 1, entry_key: "1", role: "user", content: "Our own words")
    heard = {}
    stub_request(:post, %r{#{LIVE}/live_\w+/accept}).with { heard[it.uri.path[/live_\w+/]] = JSON.parse(it.body).dig("session", "instructions") }
    froms = { "live_owner" => [ { name: "From", value: "\"Robin\" <sip:+14165550100@#{SIP_HOST}>;tag=a1" } ],
      "live_member" => [ sip("From", "16475550123") ], "live_other" => [ sip("From", "14165550199") ],
      "live_none" => [], "live_two" => [ sip("From", "14165550100"), sip("f", "14165550199") ] }
    perform_enqueued_jobs do
      froms.each do |session, from|
        deliver JSON.generate(type: "live.transport.incoming", id: "evt_#{session}", created_at: 1.hour.ago.to_i,
          data: { type: "sip", session_id: session, sip_headers: [ sip("To", DID), *from ] }), delivery: session
      end
    end

    assert_equal({ "live_owner" => "owner", "live_member" => "owner", "live_other" => "stranger", "live_none" => "stranger", "live_two" => "stranger" },
      @agent.voice_calls.pluck(:session_id, :reach).to_h)
    [ "live_owner", "live_member" ].each { assert_includes heard[it], "Our own words", it }
    [ "live_other", "live_none", "live_two" ].each { assert_not_includes heard[it], "Our own words", it }
    assert_no_match(/5550(100|123|199)/, Agent::VoiceCall.all.map(&:attributes).to_s)
  end

  test "a verified offer logs only the presence of caller identity headers" do
    body = JSON.parse(event(extra: [ sip("p-asserted-identity", "14165550177") ]))
    body["data"]["sip_headers"][1]["name"] = "f"
    output = StringIO.new
    with_logger(output) do
      deliver(body.to_json)
      body["id"] = "evt_without_identity"
      body["data"]["session_id"] = "live_no_identity"
      body["data"]["sip_headers"].slice!(1..)
      deliver(body.to_json, delivery: "without_identity")
    end

    first, second = @agent.voice_calls.order(:id).ids
    assert_includes output.string, "Voice call #{first} offer: From=present P-Asserted-Identity=present"
    assert_includes output.string, "Voice call #{second} offer: From=absent P-Asserted-Identity=absent"
    assert_no_match(/#{CALLER}|14165550177|#{API_KEY}/, output.string)
  end

  test "with voice off or no API key, nothing reaches OpenAI" do
    deliver
    with_setting(:voice, :enabled, false) { perform_enqueued_jobs }
    with_setting(:voice, :api_key, nil) { perform_enqueued_jobs { deliver event(session: "live_other", id: "evt_other"), delivery: "other" } }
    assert_not_requested :post, /openai/
    assert_equal [ nil, nil ], Agent::VoiceCall.order(:id).pluck(:outcome)
  end

  test "an uncertain accept is recorded as unknown, never retried, and the key stays out of the log" do
    accept = stub_request(:post, "#{LIVE}/live_fixture/accept").to_return(status: 503, body: "echo #{API_KEY}")
    timeout = stub_request(:post, "#{LIVE}/live_other/accept").to_raise(Net::ReadTimeout)
    Rails.logger.broadcast_to(capture = ActiveSupport::Logger.new(log = StringIO.new))
    perform_enqueued_jobs do
      [ "delivery", "retry" ].each { deliver delivery: it }
      2.times { deliver event(session: "live_other", id: "evt_other"), delivery: "other" }
    end
    assert_requested accept, times: 1
    assert_requested timeout, times: 1
    assert_equal %w[ unknown unknown ], @agent.voice_calls.order(:id).pluck(:outcome)
    assert_empty @attached, "an accept that may not have happened is not listened to"
    assert_empty @submissions
    assert_match "HTTP 503", log.string
    assert_no_match API_KEY, log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture) if capture
  end

  test "an offer for no agent, or one that conflicts, is rejected, but never a recorded session" do
    reject = stub_request(:post, "#{LIVE}/live_other/reject").with(body: { status_code: 603 }.to_json)
    with_setting(:voice, :agent_id, 0) { deliver event(session: "live_other", id: "evt_other"), status: :not_found }
    deliver
    deliver event(session: "live_other", id: "evt_other"), delivery: "delivery", status: :conflict
    deliver event(id: "evt_other"), delivery: "other", status: :conflict
    assert_requested reject, times: 2
    assert_not_requested :post, "#{LIVE}/live_fixture/reject"
  end

  private
    # OpenAI's sideband for the call, scripted: each event as it would arrive.
    def following(*events)
      attached = @attached
      DurableAssistants::Live.define_singleton_method(:attach) do |key, session_id, call_id:, &block|
        attached << [ key, session_id ]
        events.each(&block)
      end
    end

    def said(who, words, at, id) = { "type" => "session.#{who}_transcript.delta", "event_id" => id, "delta" => words, "start_ms" => at, "end_ms" => at + 200 }
    def closed(reason) = { "type" => "session.closed", "event_id" => "closed", "reason" => reason, "usage" => { "seconds" => 12 } }

    def with_logger(io)
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
    ensure
      Rails.logger = previous
    end

    def sip(name, number) = { name:, value: "<sip:+#{number}@#{SIP_HOST}>#{';tag=fake' if name == 'From'}" }

    def event(did: DID, caller: CALLER, extra: [], session: "live_fixture", id: "evt_fixture", type: "live.transport.incoming")
      JSON.pretty_generate(type:, id:, created_at: 1.hour.ago.to_i,
        data: { type: "sip", session_id: session, sip_headers: [ sip("To", did), sip("From", caller), *extra ] })
    end

    def deliver(body = event, delivery: "delivery", stamp: Time.current.to_i, key: KEY, status: :ok)
      signature = OpenSSL::HMAC.base64digest("SHA256", key, "#{delivery}.#{stamp}.#{body}")
      post "/voice/webhooks", params: body, headers: { "Content-Type" => "application/json",
        "webhook-id" => delivery, "webhook-timestamp" => stamp.to_s, "webhook-signature" => "v2,unused v1,#{signature}" }
      assert_response status
    end
end
