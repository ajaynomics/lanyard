require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/forge_socket_test_helper"
require_relative "../../test_helpers/mcp_test_helper"

class Sidecar::ForgeInvocationsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include ForgeSocketTestHelper
  include McpTestHelper

  SHA = "a" * 40
  REVISION = "b" * 40
  REPOS = (1..6).map { |id| "sample/project-#{id}" }.freeze
  SOCKET = "/run/forge-test/bridge.sock"
  FOREIGN = "https://other.example.com/path"
  FILES_UNAVAILABLE = "Forge file delivery is not available yet."
  BUSY = "Another forge call is already in progress."
  UNKNOWN = "The forge bridge did not confirm a bounded result."
  OPERATIONS = {
    "pr" => { "number" => 5 }, "diff" => { "base" => "main", "head" => SHA },
    "ci-runs" => { "head_sha" => SHA }, "ci-jobs" => { "run_id" => 7 },
    "fetch" => { "ref" => "main", "have" => [] }, "ci-log" => { "job_id" => 8, "max_bytes" => 400, "tail" => false },
    "ci-artifact" => { "run_id" => 7, "name" => "report.zip" },
    "push" => { "branch" => "review/topic", "expected_head" => "absent", "revision" => REVISION }
  }.freeze
  PR = { "number" => 5, "state" => "open", "base" => "main", "head_ref" => "review/topic", "head_sha" => SHA,
    "mergeable" => nil, "title" => "A synthetic pull request" }.freeze
  DIFF = { "base_sha" => SHA, "head_sha" => REVISION, "files" => 1, "additions" => 1, "deletions" => 0 }.freeze
  PATCH = "diff --git a/example.txt b/example.txt\n--- a/example.txt\n+++ b/example.txt\n@@ -1,0 +2 @@\n+Example\n"

  setup do
    install_sidecar_settings
    @saved_forge = Rails.application.config.x.forge
    @owner = create_user(name: "Robin")
    @team = Workspace.make(name: "Sample crew", owner: @owner)
    attributes = @owner.agents.sole.attributes.slice(*%w[ user_id instructions model thinking_level time_zone tool_names capabilities ])
    @agent = @team.agents.create!(attributes.merge(id: 19, name: "Sample desk"))
    @conversation = create_conversation(@agent)
  end

  teardown do
    Rails.application.config.x.forge = @saved_forge
    remove_sidecar_settings
  end

  test "the bound agent can read PR and CI metadata with exact wire replies" do
    enable_forge
    run = { "run_id" => 7, "workflow" => "Test", "event" => "push", "status" => "completed", "conclusion" => "success", "attempt" => 1 }
    job = { "job_id" => 8, "name" => "test", "status" => "completed", "conclusion" => "success",
      "steps" => [ { "name" => "test", "conclusion" => "success" } ] }
    results = { "pr" => PR, "ci-runs" => { "head_sha" => SHA, "runs" => [ run ] }, "ci-jobs" => { "run_id" => 7, "jobs" => [ job ] } }
    results.each do |verb, fields|
      call = payload(verb, call_id: verb)
      with_fake_forge_socket(SOCKET, reply: ->(request) { success(request, fields) }) do |socket|
        result = run_call(call).fetch("result")
        assert_equal "ok", result.fetch("status")
        assert_equal verb, result.fetch("verb")
        assert_equal REPOS.first, result.fetch("repo")
        assert_equal fields.except("title"), result.except("status", "verb", "repo")
        assert_not_includes result.to_json, PR.fetch("title")
        invocation = invocation_for(call)
        request = JSON.parse(socket.writes.sole)
        assert_equal({ "agent_id" => 19, "workspace_id" => @team.id, "conversation_id" => @conversation.id,
          "invocation_id" => invocation.id, "task_id" => invocation.task_id, "call_id" => invocation.call_id }, request.fetch("context"))
        assert_equal call.fetch(:arguments), request.fetch("operation")
        assert_equal %w[ context operation ], request.keys.sort
        InvocationCallJob.perform_now(invocation)
        assert_equal 1, socket.writes.size
      end
    end
  end

  test "only the persisted binding can use the eight verbs and none of them visits the socket for a foreign agent" do
    enable_forge
    other = create_conversation(@owner.start_agent("Other desk", workspace: @team), durable_id: "13")
    other.agent.update!(tool_names: [ "forge" ])
    assert_nil other.tool("forge")
    OPERATIONS.each_key { |verb| refused(payload(verb, conversation: other)) }
    assert_empty other.invocations
    enable_forge(workspace_id: @owner.personal_workspace.id)
    OPERATIONS.each_key { |verb| refused(payload(verb)) }
    assert_empty @conversation.invocations
  end

  test "configuration is opt-in and exactly six distinct repos are needed" do
    @agent.update!(tool_names: [ "forge" ])
    assert_nil @conversation.tool("forge")
    [ { repos: REPOS.take(5).join(",") }, { repos: ([ REPOS[0] ] * 6).join(",") }, { socket_path: FOREIGN },
      { repos: (REPOS.take(5) + [ "other/project" ]).join(",") }, { branch_namespace: "review/*" } ].each do |config|
      enable_forge(**config)
      assert_nil @conversation.tool("forge")
      refused(payload)
    end
    enable_forge
    assert_equal Tool::Forge, @conversation.tool("forge")
    @agent.update!(disabled_tools: @agent.disabled_tools | [ "forge" ])
    refused(payload)
  end

  test "each exact repo is allowed, but a sibling repo reaches no wrapper" do
    enable_forge
    REPOS.each_with_index do |repo, index|
      call = payload(arguments: operation("pr").merge("repo" => repo), call_id: "repo-#{index}")
      with_fake_forge_socket(SOCKET, reply: ->(request) { success(request, PR) }) do |socket|
        assert_equal repo, run_call(call).dig("result", "repo")
        assert_equal 1, socket.writes.size
      end
    end
    refused(payload(arguments: operation("pr").merge("repo" => "sample/project-7")))
  end

  test "forge stays in lookup when the agent fills its declaration budget" do
    enable_forge
    assert_includes @conversation.lookup_tools, Tool::Forge
    tools = Array.new(Agent::TOOL_LIMIT - @agent.tool_count) { { "name" => "sample_#{it}" } }
    make_core(@agent, @team.mcp_servers.create!(user: @owner, name: "sample", url: MCP_URL, tools: tools))
    declared, searched = @agent.reload.toolset(@conversation.connectors)
    assert_equal @agent.declared_tool_limit - @agent.lookup_sidecar_tool_names.size, declared.size, "the sidecar's own tools count, including tool_search"
    assert_not_includes declared, Tool::Forge
    assert_equal 1, searched.count(Tool::Forge)
  end

  test "invalid and extra fields reach no socket or ledger, for every verb" do
    enable_forge
    OPERATIONS.each_key do |verb|
      %w[ actor agent_id workspace_id task_id invocation_id call_id context command path host url credential token key challenge receipt_id force ].each do |field|
        refused(payload(verb, arguments: operation(verb).merge(field => FOREIGN)))
      end
    end
    bad = [ operation("pr").merge("number" => 10_000_001), operation("pr").merge("number" => 1.0), operation("pr").except("number"),
      operation("pr").merge("verb" => "ci-status"), operation("ci-jobs").merge("run_id" => 10**12 + 1),
      operation("ci-log").merge("tail" => "false"), operation("ci-log").merge("max_bytes" => 262_145),
      operation("fetch").merge("have" => Array.new(33, SHA)), operation("fetch").merge("ref" => "main/../other"),
      operation("diff").merge("head" => "main/name.lock/sub"), operation("diff").merge("head" => "main//other"),
      operation("ci-artifact").merge("name" => "../report.zip"), operation("ci-runs").merge("head_sha" => "HEAD"),
      *%w[ main other/topic review/topic/ review/a/b/c/d/e review/a.lock refs/heads/review/topic ].map { |branch| operation("push").merge("branch" => branch) },
      operation("push").merge("expected_head" => "0" * 40), operation("push").merge("revision" => "0" * 40) ]
    bad.each { |arguments| refused(payload(arguments:)) }
    refused(payload(tool: "use_tool", arguments: { "name" => "forge", "arguments" => operation("pr"), "url" => FOREIGN }))
    assert_empty @conversation.invocations
  end

  test "workspace files and pushes refuse with fixed text before queueing any job or opening a socket" do
    enable_forge
    %w[ fetch ci-log ci-artifact push ].each do |verb|
      call = payload(verb, call_id: verb)
      live(call)
      with_fake_forge_socket(SOCKET) do |socket|
        assert_no_enqueued_jobs(only: InvocationCallJob) { post_call(call) }
        assert_response :ok
        assert_equal({ "status" => "done", "result" => { "error" => FILES_UNAVAILABLE }, "isError" => true }, response.parsed_body)
        invocation = invocation_for(call)
        assert invocation.failed?
        assert_nil invocation.approval
        assert_nil invocation.result
        assert_empty socket.writes
      end
    end
  end

  test "a staged diff reports verified counts and untrusted patch, never as a file result" do
    enable_forge
    with_patch(PATCH) do |socket|
      outcome = run_call(payload("diff"))
      assert_equal false, outcome.fetch("isError")
      assert_not outcome.key?("file")
      result = outcome.fetch("result")
      assert_equal DIFF, result.slice(*DIFF.keys)
      assert_equal PATCH, result.fetch("untrusted_patch")
      assert_equal false, result.fetch("truncated")
      assert_equal Digest::SHA256.hexdigest(PATCH), result.fetch("sha256")
      assert_equal 1, socket.writes.size
    end
  end

  test "a scanned large patch is capped before it can spill to the sidecar file fallback" do
    enable_forge
    patch = PATCH + ("+Plain text example\n" * 10_000)
    with_patch(patch) do
      result = run_call(payload("diff")).fetch("result")
      assert_equal true, result.fetch("truncated")
      assert_operator JSON.generate(result).bytesize, :<, 49_152
      assert_operator result.fetch("untrusted_patch").lines.size, :<, 2_000
      assert_not result.key?("file")
    end
  end

  test "oversize, mismatched, truncated and unsafe diff frames refuse without retaining text" do
    enable_forge
    cases = [ [ PATCH, { "sha256" => "a" * 64 }, nil ], [ PATCH, {}, 262_145 ], [ PATCH, {}, PATCH.bytesize + 1 ],
      [ PATCH.sub("+++ b/example.txt", "+++ b/../unsafe.txt"), {}, nil ] ]
    cases.each_with_index do |(patch, meta, length), index|
      with_patch(patch, **meta.symbolize_keys, length:) do
        call = payload("diff", call_id: "bad-#{index}")
        assert_equal UNKNOWN, run_call(call).dig("result", "error")
        assert_nil invocation_for(call).result
        assert_equal 0, invocation_for(call).held_files.count
      end
    end
  end

  test "secret-shaped text in the patch or discarded PR title reaches no file, model, ledger or log" do
    enable_forge
    marker = "only-forge-fixture"
    secret = [ "Authorization", "Custom #{marker}" ].join(": ")
    log = StringIO.new
    logger = Logger.new(log)
    Rails.logger.broadcast_to(logger)
    begin
      pr = payload
      with_fake_forge_socket(SOCKET, reply: ->(request) { success(request, PR.merge("title" => secret)) }) do
        assert_equal UNKNOWN, run_call(pr).dig("result", "error")
        assert_not_includes response.body, marker
      end
      with_patch(PATCH + "+#{secret}\n") do
        call = payload("diff", call_id: "secret-patch")
        assert_equal UNKNOWN, run_call(call).dig("result", "error")
        assert_not_includes response.body, marker
        assert_equal 0, invocation_for(call).held_files.count
      end
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end
    [ log.string, @conversation.invocations.map(&:attributes).to_json ].each do |retained|
      [ marker, SOCKET, RAILS_TOKEN, SIDECAR_TOKEN ].each { |value| assert_not_includes retained, value }
    end
  end

  test "a second valid call is refused agent-wide while another is queued and after it starts" do
    enable_forge
    fork = @agent.conversations.create!(parent: @conversation, durable_id: "13", request_id: "r-13")
    first = payload
    live(first)
    post_call(first)
    assert_response :ok
    assert_equal "waiting", response.parsed_body.fetch("status")
    [ false, true ].each do |started|
      invocation_for(first).update!(started_at: Time.current) if started
      [ @conversation, fork ].each do |conversation|
        call = payload("ci-jobs", conversation:, call_id: "busy-#{started}")
        live(call)
        with_fake_forge_socket(SOCKET) do |socket|
          post_call(call)
          assert_equal BUSY, response.parsed_body.dig("result", "error")
          assert_empty socket.writes
        end
      end
    end
  end

  test "foreign identity, forged digest, stale and stopped calls cannot dispatch" do
    enable_forge
    other = create_user(name: "Avery")
    @team.memberships.create!(user: other, role: "member")
    refused(payload.merge(actorId: other.id.to_s), status: :forbidden)
    refused(payload.merge(digest: "0" * 64))
    call = payload
    refused(call, active: false)
    live(call)
    post_call(call)
    assert_response :ok
    assert_equal "waiting", response.parsed_body.fetch("status")
    live(call, active: false)
    with_fake_forge_socket(SOCKET) do |socket|
      InvocationCallJob.perform_now(invocation_for(call))
      assert invocation_for(call).failed?
      assert_empty socket.writes
    end
    refused(call, active: false)
  end

  test "a timeout or a bad echo is not retried and never exposes raw response text" do
    enable_forge
    replies = [ ->(_) { raise Timeout::Error, "Synthetic remote words" },
      ->(request) { success(request, PR).merge("repo" => "sample/foreign") } ]
    replies.each_with_index do |reply, index|
      call = payload(call_id: "unknown-#{index}")
      with_fake_forge_socket(SOCKET, reply:) do |socket|
        assert_equal UNKNOWN, run_call(call).dig("result", "error")
        invocation = invocation_for(call)
        assert_nil invocation.result
        assert_not_includes invocation.attributes.to_json, "Synthetic remote words"
        InvocationCallJob.perform_now(invocation)
        assert_equal 1, socket.writes.size
      end
    end
  end

  test "forge has no approver note or approval card" do
    enable_forge
    push = operation("push")
    noted = push.merge("note_to_approver" => "From an older tool declaration.")
    refused(payload("push", arguments: noted))
    refused(payload(tool: "use_tool", arguments: { "name" => "forge", "arguments" => noted }))
    assert_nil Tool::Forge.asks
    refute Tool::Forge.even_approving_everything?
    refute Tool::Forge.notes_to_approver?

    call = payload("push", call_id: "direct-push")
    live(call)
    with_fake_forge_socket(SOCKET) do |socket|
      post_call(call.merge(handBack: true))
      assert_response :ok
      assert_equal FILES_UNAVAILABLE, response.parsed_body.dig("result", "error")
      invocation = invocation_for(call)
      assert_nil invocation.approval
      refute invocation.own_approval_card?
      assert_empty socket.writes
    end
  end

  private
    def enable_forge(**overrides)
      Rails.application.config.x.forge = { agent_id: @agent.id, workspace_id: @team.id,
        repos: REPOS.join(","), branch_namespace: "review", socket_path: SOCKET }.merge(overrides)
      @agent.update!(tool_names: @agent.tool_names | [ "forge" ])
      @conversation.reload
    end

    def operation(verb) = { "verb" => verb, "repo" => REPOS.first }.merge(OPERATIONS.fetch(verb))

    def payload(verb = "pr", conversation: @conversation, tool: "forge", arguments: operation(verb), **identity)
      invocation_payload(conversation, tool:, arguments:, **identity)
    end

    def live(call, active: true)
      query = call.slice(:actorId, :workspaceId, :taskId, :callId, :digest).transform_keys(&:to_s).transform_values(&:to_s)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{call.fetch(:conversationId)}").with(query: query)
        .to_return(body: { activeInvocation: active }.to_json)
    end

    def post_call(call) = post("/agent/invocations", params: call, headers: rails_bearer, as: :json)

    def refused(call, status: :conflict, active: true)
      live(call, active:)
      with_fake_forge_socket(SOCKET) do |socket|
        post_call(call)
        assert_response status
        assert_empty socket.writes
      end
    end

    def invocation_for(call) = @agent.conversations.find_by!(durable_id: call.fetch(:conversationId)).invocations.find_by!(call_id: call.fetch(:callId))

    def run_call(call)
      live(call)
      post_call(call)
      assert_response :ok
      assert_equal "waiting", response.parsed_body.fetch("status")
      InvocationCallJob.perform_now(invocation_for(call))
      post_call(call)
      assert_response :ok
      response.parsed_body
    end

    def success(request, fields) = request.fetch("operation").slice("verb", "repo").merge("status" => "ok").merge(fields)

    def with_patch(patch, length: nil, **meta, &block)
      fields = DIFF.merge("bytes" => patch.bytesize, "sha256" => Digest::SHA256.hexdigest(patch)).merge(meta.stringify_keys)
      with_fake_forge_socket(SOCKET, reply: ->(request) { success(request, fields) }, frame: patch, length:, &block)
    end
end
