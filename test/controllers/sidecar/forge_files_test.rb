require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Sidecar::ForgeFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @user = create_user
    @conversation = create_conversation(@user.agents.sole)
    @call = @conversation.invocations.create!(task_id: "7", call_id: "forge_call", tool_name: "forge", arguments: {},
      digest: "a" * 64, state: :running, started_at: Time.current)
  end
  teardown { remove_sidecar_settings }

  test "a forge upload preflight names a live call but cannot invent its transfer" do
    with_binding do
      post "/agent/uploads", headers: forge_headers("push-check", "f" * 32)
      assert_response :not_found
    end
  end

  test "the typed caller stages a verified file and the generic callback cannot fetch it" do
    with_binding do
      client = Object.new
      client.define_singleton_method(:forge_file) do |_access, _conversation, **offer|
        yield_transfer.call(offer)
      end
      bytes = "synthetic binary\x00\xff".b
      sha = Digest::SHA256.hexdigest(bytes)
      delivered = nil
      transfer = lambda do |offer|
        delivered = offer.fetch(:transfer)
        post "/agent/files", headers: forge_headers("stage", delivered)
        assert_response :ok
        assert_equal bytes.bytesize.to_s, response.headers["Content-Length"]
        assert_equal bytes, response.body.b
        post "/agent/files", headers: rails_bearer, as: :json, params: { actorId: @user.id.to_s,
          workspaceId: @conversation.agent_id.to_s, conversationId: @conversation.durable_id, taskId: @call.task_id, callId: @call.call_id }
        assert_response :gone
        { "transferred" => true }
      end
      client.define_singleton_method(:yield_transfer) { transfer }
      seam = ForgeFiles.new(@call, client: client)
      result = seam.stage(io: StringIO.new(bytes), bytes: bytes.bytesize, sha256: sha)
      assert_equal "/home/agent/.forge/#{sha}.bundle", result.path
      post "/agent/files", headers: forge_headers("stage", delivered)
      assert_response :not_found
      assert_empty @call.reload.held_files
      assert_raises(ForgeFiles::Invalid) { seam.stage(io: StringIO.new("wrong"), bytes: bytes.bytesize, sha256: sha) }
      assert_raises(ForgeFiles::TooLarge) { seam.stage(io: StringIO.new, bytes: ForgeFiles::MAX_BYTES + 1, sha256: sha) }
    end
  end

  test "only a verified binary upload is consumed, once, with nothing in the ledger or log" do
    bytes = "synthetic\x00forge-private-marker\xff".b
    sha = Digest::SHA256.hexdigest(bytes)
    logs = StringIO.new
    capture = ActiveSupport::Logger.new(logs, level: :debug)
    Rails.logger.broadcast_to(capture)
    client = Object.new
    receive = lambda do |offer|
      headers = forge_headers("push", offer.fetch(:transfer))
      assert_equal 204, raw_upload(headers, Input.new(bytes), bytes.bytesize)
      replay = Input.new(bytes)
      assert_equal 409, raw_upload(headers, replay, bytes.bytesize)
      assert_equal 0, replay.reads
      { "transferred" => true }
    end
    client.define_singleton_method(:forge_file) { |*, **offer| receive.call(offer) }
    with_binding do
      read = ForgeFiles.new(@call, client: client).take(bytes: bytes.bytesize, sha256: sha) do |io|
        assert_equal bytes.bytesize, io.stat.size
        io.read
      end
      assert_equal bytes, read
      assert_empty @conversation.uploads
      assert_empty @call.reload.held_files
      assert_nil @call.result
      assert_no_match(/forge-private-marker|#{Regexp.escape(RAILS_TOKEN)}|incoming-/, logs.string)
      assert_no_match(/forge-private-marker|#{Regexp.escape(RAILS_TOKEN)}/, @call.attributes.to_json)
    end
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  test "wrong hash, short, long, interrupted and extra-byte uploads cannot expose a staged file" do
    bytes = "binary\x00".b
    with_binding do
      ForgeFiles::Session.start(@call, :push, bytes.bytesize, Digest::SHA256.hexdigest(bytes)) do |session|
        headers = forge_headers("push", session.id)
        [ bytes.chop, bytes + "x", "x" * bytes.bytesize ].each do |bad|
          assert_equal 422, raw_upload(headers, Input.new(bad), bytes.bytesize)
          assert_raises(Errno::ENOENT) { session.open }
        end
        interrupted = Input.new(bytes)
        def interrupted.read(*) = raise(EOFError)
        assert_equal 422, raw_upload(headers, interrupted, bytes.bytesize)
        assert_raises(Errno::ENOENT) { session.open }
        too_large = Input.new(bytes)
        assert_equal 413, raw_upload(headers, too_large, ForgeFiles::MAX_BYTES + 1)
        assert_equal 0, too_large.reads
        assert_equal 204, raw_upload(headers, Input.new(bytes), bytes.bytesize)
      end
    end
  end

  test "wrong transport, binding, caller and stale invocations are refused before request body reads" do
    bytes = "fixture"
    with_binding do
      ForgeFiles::Session.start(@call, :push, bytes.bytesize, Digest::SHA256.hexdigest(bytes)) do |session|
        headers = forge_headers("push", session.id)
        other = create_user(name: "Robin").agents.sole
        bound = { agent_id: @conversation.agent_id, workspace_id: @call.workspace.id }
        [
          [ 401, headers.merge(rails_bearer(SIDECAR_TOKEN)) ],
          [ 404, headers.merge("X-Forwarded-For" => "203.0.113.9") ],
          [ 403, headers.merge("X-Forge-Actor" => other.user_id.to_s) ],
          [ 404, headers.merge("X-Forge-Actor" => other.user_id.to_s, "X-Forge-Agent" => other.id.to_s) ],
          [ 404, headers.merge("X-Forge-Conversation" => "99") ],
          [ 422, headers.merge("X-Forge-Transfer" => "../other") ]
        ].each { |code, given| assert_unread(code, given, bytes) }
        [ "application/json", "application/x-www-form-urlencoded" ].each do |type|
          body = Input.new(bytes)
          assert_equal 422, raw_upload(headers, body, bytes.bytesize, type: type, path: "/agent/uploads.json/")
          assert_equal 0, body.reads
        end
        with_setting(:pi_durable, :forge_files, bound.merge(workspace_id: other.workspace_id)) { assert_unread(403, headers, bytes) }
        with_setting(:access, :emails, []) { assert_unread(403, headers, bytes) }
        @conversation.agent.update!(paused_at: Time.current)
        assert_unread 403, headers, bytes
        @conversation.agent.update!(paused_at: nil)
        [ { tool_name: "send_email" }, { call_id: "helper/inner" }, { started_at: nil },
          { started_at: 6.minutes.ago }, { state: :succeeded } ].each do |change|
          @call.update!(**{ tool_name: "forge", call_id: "forge_call", started_at: Time.current, state: :running }.merge(change))
          assert_unread 403, forge_headers("push", session.id), bytes
          post "/agent/files", headers: forge_headers("stage", session.id)
          assert_response :forbidden
        end
        assert_raises(Errno::ENOENT) { session.open }
        assert_empty @conversation.uploads
      end
    end
  end

  class Input < StringIO
    attr_reader :reads
    def initialize(bytes)
      super(bytes.b)
      @reads = 0
    end

    def read(size = nil, buffer = nil)
      @reads += 1
      raise "unbounded rack.input read" unless size&.between?(1, ForgeFiles::CHUNK_BYTES)

      super
    end
  end

  private
    def assert_unread(status, headers, bytes)
      body = Input.new(bytes)
      assert_equal status, raw_upload(headers, body, bytes.bytesize)
      assert_equal 0, body.reads
    end

    def raw_upload(headers, input, size, type: "application/octet-stream", path: "/agent/uploads")
      env = Rack::MockRequest.env_for(path, method: "POST")
      headers.each { |key, value| env["HTTP_#{key.upcase.tr('-', '_')}"] = value }
      response = Rails.application.call(env.merge("CONTENT_TYPE" => type,
        "CONTENT_LENGTH" => size.to_s, "rack.input" => input))
      response[2].close if response[2].respond_to?(:close)
      response[0]
    end

    def with_binding(agent = @conversation.agent)
      with_setting(:access, :emails, [ @user.email ]) do
        with_setting(:pi_durable, :forge_files, { agent_id: agent.id, workspace_id: agent.workspace_id }) { yield }
      end
    end

    def forge_headers(mode, transfer)
      rails_bearer.merge("X-Forge-Mode" => mode, "X-Forge-Transfer" => transfer,
        "X-Forge-Actor" => @user.id.to_s, "X-Forge-Agent" => @conversation.agent_id.to_s,
        "X-Forge-Conversation" => @conversation.durable_id, "X-Forge-Task" => @call.task_id, "X-Forge-Call" => @call.call_id)
    end
end
