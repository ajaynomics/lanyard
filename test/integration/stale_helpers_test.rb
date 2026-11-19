require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A background helper whose end report never reaches Rails (one agent's helper
# 95, 2026-11-15: reports until 09:11:19Z, then nothing, still running at
# 20:38Z, and the footer counted it). The minute's sweep settles it once the
# sidecar no longer runs it, or once it has been quiet too long; never one the
# sidecar still runs and that has reported lately.
class StaleHelpersTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  STATUS = %r{\A#{SIDECAR}/v1/conversations/12/helpers\?}

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @submissions = []
    @cancels = []
    @asked = []
    @sidecar = {}
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return { |request|
      @cancels << JSON.parse(request.body)
      { body: { cancelled: true, count: 0, tools: [] }.to_json } }
    stub_request(:get, STATUS).to_return { |request|
      call_id = Rack::Utils.parse_query(URI(request.uri).query)["callId"]
      @asked << call_id
      case (status = @sidecar.fetch(call_id, "running"))
      when Integer then { status: status, body: { error: status == 404 ? "not_found" : "unavailable" }.to_json }
      else { body: { status: status }.to_json }
      end }
  end
  teardown do
    travel_back
    remove_sidecar_settings
  end

  test "helper 95: its end report lost, hours later the sidecar has its task as ended, and the sweep settles it" do
    replay_helper_95
    @sidecar["toolu_95"] = "terminal"

    assert_logged(/Settled helper #{@lost.id} .* of conversation #{@conversation.id} as failed \(lost\)/) { ConversationRecoveryJob.perform_now }

    assert_settled_as_lost
  end

  test "helper 95: its end report lost, hours later the sidecar has lost its task (404), and the sweep settles it" do
    replay_helper_95
    @sidecar["toolu_95"] = 404

    ConversationRecoveryJob.perform_now

    assert_settled_as_lost
  end

  test "one the sidecar still runs stays working, and one it can't be asked about waits for the next minute" do
    replay_helper_95
    ConversationRecoveryJob.perform_now
    assert_predicate @lost.reload, :running?

    @sidecar["toolu_95"] = 503
    ConversationRecoveryJob.perform_now
    assert_predicate @lost.reload, :running?
    assert_equal 2, Conversation::StatusLine.new(@conversation).helpers_working
    assert_empty @cancels
  end

  test "one quiet longer than any real helper is stopped and settled, though the sidecar says it runs" do
    travel_to Time.utc(2026, 11, 15, 8, 48, 28)
    report "toolu_q", state: "running"
    quiet = @conversation.helpers.find_by!(call_id: "toolu_q")

    # A day waiting on a person's approval, and a day of end-report retries: quiet, and still a real helper.
    travel Helper::QUIET - 1.minute
    ConversationRecoveryJob.perform_now
    assert_predicate quiet.reload, :running?

    travel 2.minutes
    assert_logged(/Settled helper #{quiet.id} .* as failed \(quiet\)/) { ConversationRecoveryJob.perform_now }
    assert_equal [ "toolu_q" ], @cancels.pluck("callId"), "the sidecar is told to stop it"
    assert_predicate quiet.reload, :failed?
    assert_equal "quiet", quiet.reason
    assert_match(/The helper stopped without an answer: it sent no word for three days\./, words(@submissions.sole["content"]))
    assert_equal 0, Conversation::StatusLine.new(@conversation).helpers_working
  end

  test "the footer's count is a link to the agent's Helpers panel" do
    report "toolu_h", state: "running"
    sign_in_via_ajent(subject: @alice.oidc_sub, email: "operator@example.com", name: @alice.name)
    get conversation_path(@conversation)
    assert_select "a.status-line__helpers[href=?]", agent_helpers_path(@agent), text: "1 helper working"
  end

  private
    # Started by message 66540 at 08:46:39Z, its row made by the first report
    # at 08:48:28Z, 114 reports to 09:11:19Z, no end; helper 129 started since.
    def replay_helper_95
      travel_to Time.utc(2026, 11, 15, 8, 48, 28)
      started = Time.current
      114.times do |n|
        travel_to started + ((n * 1371.0 / 113).seconds)
        report "toolu_95", state: "running", tools: [ { callId: "t#{n}", name: "bash", status: "done" } ], count: n + 1
      end
      @lost = @conversation.helpers.find_by!(call_id: "toolu_95")
      assert_equal Time.utc(2026, 11, 15, 9, 11, 19), @lost.updated_at.change(usec: 0)

      travel_to Time.utc(2026, 11, 15, 20, 37)
      report "toolu_129", state: "running"
      @live = @conversation.helpers.find_by!(call_id: "toolu_129")
      travel_to Time.utc(2026, 11, 15, 20, 38)
      assert_predicate @lost.reload, :running?
      assert_nil @lost.finished_at
      assert_equal 2, Conversation::StatusLine.new(@conversation).helpers_working
    end

    def assert_settled_as_lost
      @lost.reload
      assert_predicate @lost, :failed?
      assert_equal "lost", @lost.reason
      assert_equal Time.current, @lost.finished_at
      assert_equal 114, @lost.call_count, "what it had done is kept"
      assert_match(/The helper stopped without an answer: its end never reached here, and the sidecar no longer runs it\./,
        words(@submissions.sole["content"]))
      assert_predicate @live.reload, :running?
      assert_not_includes @asked, "toolu_129", "one that reported lately is not asked about"
      assert_empty @cancels, "nothing is stopped or run again"
      assert_equal 1, Conversation::StatusLine.new(@conversation).helpers_working

      ConversationRecoveryJob.perform_now
      assert_equal 1, @submissions.size, "settled once"
    end

    def report(call_id, **data)
      post "/agent/helpers", params: { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s, conversationId: "12", callId: call_id,
        task: "Look into #{call_id}.", tools: [], count: 0 }.merge(data), headers: rails_bearer, as: :json
      assert_response :no_content
    end

    def assert_logged(pattern)
      output = StringIO.new
      logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      yield
      assert_match pattern, output.string
    ensure
      Rails.logger = logger
    end
end
