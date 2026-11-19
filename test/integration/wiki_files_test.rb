require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# An attachment the office's wiki fetched (McpServer::WikiAttachment): the
# call answers with what the file is, as Google's file tools do, and the
# sidecar then fetches its bytes once. The wiki's link names its public
# address, which an agent's computer can't reach; the app fetches the link's
# path from the connector's own address instead, and nowhere else.
class WikiFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze
  INSIDE = "http://example-wiki:3000".freeze
  PUBLIC = "https://wiki.example.com".freeze
  SIGNED = "/api/files.get?key=uploads%2Fplan.pdf&sig=abc".freeze
  PDF = "%PDF-1.7\n\xE2\xE3\xCF\xD3 binary".b.freeze

  setup do
    install_sidecar_settings
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "wiki-key", tools: %w[ fetch ], fetches_attachments: true } }
    @link = "#{PUBLIC}#{SIGNED}"
    @size = PDF.bytesize.to_s
    stub_mcp_server(url: WIKI, tools: [ mcp_tool("fetch", annotations: { readOnlyHint: true }) ], calls: { "fetch" => ->(arguments) {
      found = if arguments["resource"] == "attachment"
        { id: arguments["id"], name: "../Plan.pdf", contentType: "application/pdf", size: @size, signedUrl: @link }.compact
      else { id: arguments["id"], title: "Plan", text: "The plan." }
      end
      { content: [ { type: "text", text: found.to_json } ] }
    } })
    # The office's owner (OFFICE__OWNER_EMAIL): her workspace may use the install's key.
    @owner_email, Rails.application.config.x.office[:owner_email] = Rails.application.config.x.office[:owner_email], "operator@example.com"
    @alice = create_user(name: "Alice", email: "operator@example.com")
    McpServer.turn_on(@alice.personal_workspace, "wiki")
    perform_enqueued_jobs(only: McpServerRefreshJob)
    @conversation = create_conversation(@alice.agents.sole)
  end

  teardown do
    Rails.application.config.x.install_connectors = @previous
    Rails.application.config.x.office[:owner_email] = @owner_email
    remove_sidecar_settings
  end

  test "an attachment is named as a file and fetched from the connector's address, never the host its link names" do
    bytes = stub_request(:get, "#{INSIDE}#{SIGNED}")
      .with(headers: { "Host" => "wiki.example.com", "X-Forwarded-Proto" => "https", "Authorization" => "Bearer wiki-key" }).to_return(body: PDF)
    done = run_call({ "resource" => "attachment", "id" => "a1" })

    assert_equal true, done["file"]
    assert_equal({ "name" => "Plan.pdf", "type" => "application/pdf", "size" => PDF.bytesize }, done.dig("result", "file"))
    assert_not_requested bytes

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PDF, response.body.b
    assert_requested bytes, times: 1
    assert_not_requested :any, /wiki\.example\.com/
  end

  test "only entries configured to fetch attachments produce a file, independent of their name" do
    config = Rails.application.config.x
    entry = config.install_connectors.fetch(:wiki)
    config.install_connectors = { wiki: entry.except(:fetches_attachments), documents: entry }
    McpServer.turn_on(@alice.personal_workspace, "documents")
    perform_enqueued_jobs(only: McpServerRefreshJob)
    arguments = { "resource" => "attachment", "id" => "a1" }

    assert_equal true, run_call(arguments, connector: "documents")["file"]
    assert_nil run_call(arguments, call_id: "toolu_2")["file"]
  end

  # The workspace's own wiki key (Workspace::InstallConnector) bounds what the
  # connector reads, so the download must not fall back to the install's.
  test "a workspace with its own wiki key fetches the attachment with that key, never the install's" do
    @alice.personal_workspace.install_connectors.create!(name: "wiki", api_key: "workspace-wiki-key")
    bytes = stub_request(:get, "#{INSIDE}#{SIGNED}").to_return(body: PDF)
    run_call({ "resource" => "attachment", "id" => "a1" })

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_requested bytes.with(headers: { "Authorization" => "Bearer workspace-wiki-key" }), times: 1
    assert_requested :post, WIKI, headers: { "Authorization" => "Bearer workspace-wiki-key" }, at_least_times: 1
    assert_not_requested :get, /example-wiki/, headers: { "Authorization" => "Bearer wiki-key" }
  end

  test "any other fetch answers as it did" do
    done = run_call({ "resource" => "document", "id" => "d1" })

    assert_nil done["file"]
    assert_equal({ "text" => { id: "d1", title: "Plan", text: "The plan." }.to_json }, done["result"])
    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :gone
  end

  test "a link to anything but a download is refused" do
    @link = "#{PUBLIC}/api/users.info?id=u1"
    run_call({ "resource" => "attachment", "id" => "a1" })

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :bad_gateway
    assert_not_requested :get, /example/
  end

  test "a redirect is followed on the link's own host, to the connector's address, and never to another host" do
    @link = "#{PUBLIC}/api/attachments.redirect?id=a1"
    stub_request(:get, "#{INSIDE}/api/attachments.redirect?id=a1").to_return(status: 302, headers: { "Location" => SIGNED })
    bytes = stub_request(:get, "#{INSIDE}#{SIGNED}").with(headers: { "Host" => "wiki.example.com", "Authorization" => "Bearer wiki-key" }).to_return(body: PDF)
    run_call({ "resource" => "attachment", "id" => "a1" })
    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_requested bytes, times: 1

    stub_request(:get, "#{INSIDE}#{SIGNED}").to_return(status: 302, headers: { "Location" => "https://files.example.net/plan.pdf?sig=x" })
    run_call({ "resource" => "attachment", "id" => "a2" }, call_id: "toolu_2")
    post "/agent/files", params: fetch(call_id: "toolu_2"), headers: rails_bearer, as: :json
    assert_response :bad_gateway
    assert_not_requested :any, /files\.example\.net/
  end

  test "a 30 MB attachment reaches the sidecar whole, and the file it waited in is gone once sent" do
    big = Random.new(3).bytes(30.megabytes)
    waiting = -> { Dir.glob(File.join(Dir.tmpdir, "wiki-attachment*-#{Process.pid}-*")) }
    before = waiting.call
    @size = big.bytesize.to_s
    stub_request(:get, "#{INSIDE}#{SIGNED}").to_return(body: big)
    done = run_call({ "resource" => "attachment", "id" => "a1" })
    assert_equal true, done["file"]

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal big.bytesize.to_s, response.headers["Content-Length"]
    assert_equal Digest::SHA256.hexdigest(big), Digest::SHA256.hexdigest(response.body.b)
    assert_empty waiting.call - before, "an earlier test's file, collected meanwhile, is no matter; this one's is gone"
  end

  test "a body over 25 MB is written whole to a file, whatever its Content-Length says, and the file goes once read" do
    big = 30.megabytes
    [ {}, { "Content-Length" => "1" } ].each do |headers|
      reply = StreamingReply.new([ "x" * big, "tail" ], headers: headers)
      with_streams(reply) do |reader, _connections|
        file = reader.send(:bytes, URI(@link))
        assert_equal big + 4, file.size
        assert_equal "tail", (file.seek(-4, IO::SEEK_END) && file.read)
        file.close!
      end
      assert_equal big + 4, reply.consumed
    end
  end

  test "redirect headers are not drained and the redirected body is read whole" do
    redirect = StreamingReply.new([ "unread redirect body" ], status: "302", headers: { "Location" => SIGNED })
    reply = StreamingReply.new([ "x" * 30.megabytes, "!", "tail" ])
    with_streams(redirect, reply) do |reader, connections|
      assert_equal 30.megabytes + 5, taken(reader.send(:bytes, URI("#{PUBLIC}/api/attachments.redirect?id=a1"))).bytesize
      assert_equal 2, connections.size
      assert_equal [ "/api/attachments.redirect?id=a1", SIGNED ], connections.map { it.requested.path }
      connections.each do |http|
        assert_equal "wiki.example.com", http.requested["Host"]
        assert_equal "https", http.requested["X-Forwarded-Proto"]
        assert_equal "Bearer wiki-key", http.requested["Authorization"]
      end
    end
    assert_equal 0, redirect.consumed
    assert_equal 30.megabytes + 5, reply.consumed
  end

  test "error and refused redirect bodies are never drained and errors do not expose their content" do
    [ [ "500", {} ], [ "302", { "Location" => "https://elsewhere.example/api/files.get?secret=x" } ] ].each do |status, headers|
      reply = StreamingReply.new([ "private body" ], status: status, headers: headers)
      with_streams(reply) do |reader, connections|
        error = assert_raises(McpServer::Unreachable) { reader.send(:bytes, URI(@link)) }
        assert_equal 1, connections.size
        assert_no_match(/private|secret|elsewhere\.example/, error.message)
      end
      assert_equal 0, reply.consumed
    end
  end

  test "steady chunks are never cut, however long the whole takes" do
    reply = StreamingReply.new(Array.new(10, "x"), seconds_per_chunk: 10)
    with_streams(reply) do |reader, connections|
      assert_equal "x" * 10, taken(reader.send(:bytes, URI(@link)))
      assert_equal [ 30 ], connections.sole.read_timeouts.uniq, "each wait for bytes gets the same 30 seconds"
    end
    assert_equal 10, reply.chunks_read
  end

  test "thirty seconds with no bytes fails, before the headers or between chunks" do
    [ StreamingReply.new([ "x", "unread" ], seconds_per_chunk: 31), StreamingReply.new([ "unread" ], seconds_to_headers: 31) ].each do |reply|
      with_streams(reply) do |reader, _connections|
        error = assert_raises(McpServer::Unreachable) { reader.send(:bytes, URI(@link)) }
        assert_equal "Could not reach wiki: ReadTimeout", error.message
      end
      assert_equal 0, reply.consumed
    end
  end

  test "each connection, a redirect's too, waits its own 30 seconds, and one slower to open never starts a request" do
    redirect = StreamingReply.new([ "unread" ], status: "302", headers: { "Location" => SIGNED }, seconds_to_headers: 25)
    reply = StreamingReply.new([ "x", "y", "z" ], seconds_per_chunk: 25)
    with_streams(redirect, reply, connect_delays: [ 25, 25 ]) do |reader, connections|
      assert_equal "xyz", taken(reader.send(:bytes, URI(@link)))
      assert_equal [ 30, 30 ], connections.map(&:open_timeout)
    end
    assert_equal 0, redirect.consumed

    slow = StreamingReply.new([ "unread" ])
    with_streams(slow, connect_delays: [ 31 ]) do |reader, connections|
      assert_equal "Could not reach wiki: OpenTimeout", assert_raises(McpServer::Unreachable) { reader.send(:bytes, URI(@link)) }.message
      assert_nil connections.sole.requested
    end
    assert_equal 0, slow.consumed
  end

  # Like Net::HTTP, a normal return from its response block drains the body.
  # A nonlocal return or exception must bypass that drain. Chunks are lazy:
  # consumed counts what the reader actually requested, not a prebuffered body.
  # Its delays stand in for the socket's: a wait for bytes longer than the
  # connection's read_timeout raises Net::ReadTimeout, as Net::HTTP does.
  class StreamingReply
    attr_reader :consumed, :chunks_read, :seconds_to_headers

    def initialize(chunks, status: "200", headers: {}, seconds_per_chunk: 0, seconds_to_headers: 0)
      @chunks, @seconds_per_chunk, @seconds_to_headers = chunks, seconds_per_chunk, seconds_to_headers
      @response = Net::HTTPResponse.send(:response_class, status).new("1.1", status, "test")
      headers.each { |name, value| @response[name] = value }
      @consumed = @chunks_read = 0
    end

    def response(http)
      reply = self
      @response.define_singleton_method(:read_body) do |&block|
        reply.read(http, &block)
      end
      @response.define_singleton_method(:body) { reply.read(http) }
      @response
    end

    def read(http)
      return @body if @body
      bytes = +"".b
      @chunks.each do |chunk|
        raise Net::ReadTimeout if @seconds_per_chunk > http.read_timeouts.last
        @consumed += chunk.bytesize
        @chunks_read += 1
        block_given? ? yield(chunk) : bytes << chunk
      end
      @body = bytes
    end
  end

  class StreamingHttp
    attr_accessor :open_timeout, :write_timeout, :max_retries
    attr_reader :requested, :read_timeouts

    def initialize(reply)
      @reply = reply
      @response = reply.response(self)
      @read_timeouts = []
    end

    def read_timeout=(seconds)
      @read_timeouts << seconds
    end

    def request(request)
      @requested = request
      raise Net::ReadTimeout if @reply.seconds_to_headers > @read_timeouts.last
      yield @response if block_given?
      @response.body
      @response
    end
  end

  private
    # A download's bytes, its Tempfile removed.
    def taken(file) = file.read.tap { file.close! }

    def with_streams(*replies, connect_delays: [])
      connections = []
      reader = McpServer::WikiAttachment.new(@alice.personal_workspace.mcp_servers.new(name: "wiki", install: "wiki", url: WIKI, token: "wiki-key"))
      start = lambda do |host, port, **options, &block|
        assert_equal "example-wiki", host
        assert_equal 3000, port
        reply = replies.shift or flunk "unexpected extra connection"
        http = StreamingHttp.new(reply)
        options.except(:use_ssl).each { |name, value| http.public_send("#{name}=", value) }
        connections << http
        raise Net::OpenTimeout if connect_delays.shift.to_i > http.open_timeout
        block.call(http)
      end
      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |*args, **options, &block| start.call(*args, **options, &block) }
      yield reader, connections
    ensure
      Net::HTTP.define_singleton_method(:start, original) if original
    end

    def run_call(arguments, call_id: "toolu_1", connector: "wiki")
      invoke(arguments, call_id, connector)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(arguments, call_id, connector)
    end

    def invoke(arguments, call_id, connector = "wiki")
      @last = invocation_payload(@conversation, tool: "mcp__#{connector}__fetch", arguments: arguments, call_id: call_id)
      post "/agent/invocations", params: @last, headers: rails_bearer, as: :json
      response.parsed_body
    end

    def fetch(call_id: "toolu_1")
      { actorId: @last[:actorId], workspaceId: @last[:workspaceId], conversationId: @last[:conversationId], taskId: @last[:taskId], callId: call_id }
    end
end
