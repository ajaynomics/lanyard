require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

class WikiUploadsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  TOOL = "mcp__wiki__upload_attachment".freeze
  PATH = "/home/agent/dot.png".freeze
  PUBLIC = "https://wiki.example.test".freeze
  UPLOAD = "/api/files.create".freeze
  DOWNLOAD = "/api/files.get?key=uploads%2Fdot.png&sig=download".freeze
  JSON_HEADERS = { "Content-Type" => "application/json; charset=utf-8" }.freeze
  CONFIRMED = '{"success":true}'.freeze

  setup do
    install_sidecar_settings
    @socket = TCPServer.new("127.0.0.1", 0)
    @inside = "http://127.0.0.1:#{@socket.addr[1]}"
    @wiki = "#{@inside}/mcp"
    @upload_url = "#{PUBLIC}#{UPLOAD}?ignored=private-query"
    @png = "\x89PNG\r\n\x1a\n".b + png_chunk("IHDR", [ 1, 1, 8, 0, 0, 0, 0 ].pack("NNCCCCC")) +
      png_chunk("IDAT", Zlib.deflate("\x00\xff".b)) + png_chunk("IEND", "")
    @attachment = { "id" => "a1", "url" => "#{PUBLIC}/api/attachments.redirect?id=a1", "name" => "dot.png", "size" => @png.bytesize }
    @max_upload_size = 1.megabyte
    @mode = "post"
    @curl = "curl with private signature"
    @created = []
    x = Rails.application.config.x
    @entries, x.install_connectors = x.install_connectors, { wiki: { url: @wiki, api_key: "wiki-key", tools: %w[ fetch ], fetches_attachments: true, uploads_attachments: true } }
    @owner_email, x.office[:owner_email] = x.office[:owner_email], "operator@example.com"
    stub_wiki
    @alice = create_user(email: "operator@example.com")
    @connector = McpServer.turn_on(@alice.personal_workspace, "wiki")
    perform_enqueued_jobs(only: McpServerRefreshJob)
    @conversation = create_conversation(make_core(@alice.agents.sole, @connector))
  end

  teardown do
    @socket&.close
    Rails.application.config.x.install_connectors = @entries
    Rails.application.config.x.office[:owner_email] = @owner_email
    remove_sidecar_settings
  end

  test "the opted-in connector offers a file tool, never Outline's raw upload form tool" do
    declared = @conversation.definition[:tools].index_by { it[:name] }
    assert declared.key?(TOOL), "the wiki should offer its upload relay"
    assert_equal Tool::SendEmail.declaration[:files], declared[TOOL][:files]
    assert_equal %w[ attachments ], declared[TOOL].dig(:parameters, "required")
    assert_equal %w[ attachments content_type name ], declared[TOOL].dig(:parameters, "properties").keys.sort
    assert_not_includes declared, "mcp__wiki__create_attachment"
    assert_operator declared.size, :<=, 64
    assert_equal :approval, @conversation.tool(TOOL).asks

    @connector.refresh
    x = Rails.application.config.x
    x.install_connectors[:wiki].delete(:uploads_attachments)
    assert_nil @conversation.reload.tool(TOOL), "revocation takes effect even before refresh"
    assert_nil @conversation.tool("mcp__wiki__create_attachment")
  end

  test "a connector must advertise create_attachment before its relay is offered" do
    stub_wiki(creates: false)
    @connector.refresh
    assert_nil @conversation.reload.tool(TOOL)
  end

  test "an approved PNG upload uses the internal address, with the signed fields first, and downloads unchanged" do
    upload @png
    assert_response :no_content
    assert_equal "waiting", invoke(TOOL, arguments)["status"]
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole.reload
    assert_equal [ "dot.png (#{@png.bytesize} Bytes)" ], call.preview["attachments"]
    assert_equal({ "attachments" => call.preview["attachments"] }, call.details)
    assert_empty @created
    call.approve!(by: @alice)
    invoke(TOOL, arguments)

    stored = nil
    with_upload_response do |request|
      assert_equal "POST #{UPLOAD} HTTP/1.1", request.fetch(:line)
      headers = request.fetch(:headers)
      assert_equal "wiki.example.test", headers["host"]
      assert_equal "https", headers["x-forwarded-proto"]
      assert_not headers.key?("authorization")
      body = request.fetch(:body)
      assert_equal form_fields.keys + [ "file" ], body.scan(/Content-Disposition: form-data; name="([^"]+)"/i).flatten
      parts = Rack::Multipart.parse_multipart({ "CONTENT_TYPE" => headers.fetch("content-type"),
        "CONTENT_LENGTH" => body.bytesize.to_s, "rack.input" => StringIO.new(body) })
      assert_equal form_fields, parts.except("file")
      file = parts.fetch("file")
      assert_equal [ "dot.png", "image/png" ], file.values_at(:filename, :type)
      stored = file.fetch(:tempfile).read.b
      assert_equal Digest::SHA256.hexdigest(@png), Digest::SHA256.hexdigest(stored)
    ensure
      file&.fetch(:tempfile)&.close!
    end

    assert_equal [ { "name" => "dot.png", "contentType" => "image/png", "size" => @png.bytesize } ], @created
    result = invoke(TOOL, arguments)["result"]
    assert_equal @attachment, result
    assert_no_match(/curl|sig|form/, result.to_json)
    assert_requested :post, @wiki, headers: { "Authorization" => "Bearer wiki-key" }, at_least_times: 1

    fetch = "mcp__wiki__fetch"
    fetch_args = { "resource" => "attachment", "id" => "a1" }
    signed = stub_request(:get, "#{@inside}#{DOWNLOAD}").with(headers: { "Host" => "wiki.example.test", "Authorization" => "Bearer wiki-key" }).to_return(body: stored)
    assert_equal true, run_call(fetch, fetch_args, call_id: "read")["file"]
    identifiers = invocation_payload(@conversation, tool: fetch, arguments: fetch_args, call_id: "read").except(:tool, :arguments, :digest)
    post "/agent/files", params: identifiers, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal Digest::SHA256.hexdigest(@png), Digest::SHA256.hexdigest(response.body.b)
    assert_requested signed, times: 1
    assert_not_requested :any, /wiki\.example\.test/
  end

  test "a looked-up relay receives files called by its own name" do
    @conversation.agent.core_connectors.delete_all
    definition = @conversation.reload.definition
    assert_not_includes definition[:tools].pluck(:name), TOOL
    assert_equal Tool::SendEmail.declaration[:files], definition[:lookup].find { it[:name] == TOOL }[:files]

    args = arguments.merge("name" => "map.bin", "content_type" => "image/png")

    id = "codemode/c1"
    allow_and_approve(id, args)
    invoke(TOOL, args, call_id: id)
    with_upload_response do |request|
      assert_includes request.fetch(:body), "filename=\"map.bin\"\r\nContent-Type: image/png\r\n"
    end
    assert_equal "map.bin", @created.sole["name"]
    assert_equal "image/png", @created.sole["contentType"]
    assert_equal @attachment.merge("name" => "map.bin"), invoke(TOOL, args, call_id: id)["result"]
  end

  test "a sign-in redirect and an HTML success are both failures" do
    [ [ "302 Found", { "Location" => "#{PUBLIC}/sign-in?secret=private" } ],
      [ "200 OK", { "Content-Type" => "Text/HTML; charset=utf-8" } ] ].each_with_index do |(status, headers), i|
      id = "sign-in-#{i}"
      allow_and_approve(id)
      invoke(TOOL, arguments, call_id: id)
      with_upload_response(status, headers, "private body") do |request|
        assert_equal "POST #{UPLOAD} HTTP/1.1", request.fetch(:line)
      end
      error = invoke(TOOL, arguments, call_id: id).dig("result", "error")
      assert_match(/wiki.*upload/i, error)
      assert_no_match(/private|signed|example\.test/, error)
    end
    assert_not_requested :any, /wiki\.example\.test/
  end

  test "only a 200 JSON boolean success confirms storage" do
    bad_replies = [ [ "200 OK", JSON_HEADERS, '{"success":false,"detail":"private"}' ],
      [ "200 OK", JSON_HEADERS, '{"success":"true"}' ],
      [ "200 OK", JSON_HEADERS, "private, not JSON" ],
      [ "200 OK", { "Content-Type" => "text/plain" }, CONFIRMED ],
      [ "201 Created", JSON_HEADERS, CONFIRMED ],
      [ "204 No Content", {}, "" ] ]
    bad_replies.each_with_index do |(status, headers, body), i|
      id = "unconfirmed-#{i}"
      allow_and_approve(id)
      invoke(TOOL, arguments, call_id: id)
      with_upload_response(status, headers, body) { |request| assert_equal "POST #{UPLOAD} HTTP/1.1", request.fetch(:line) }
      result = invoke(TOOL, arguments, call_id: id)["result"]
      assert_match(/wiki.*upload/i, result["error"], status)
      assert_no_match(/private|example\.test/, result.to_json)
    end
  end

  test "PUT and unknown modes never reach storage" do
    outgoing = stub_request(:post, /\/api\/files\.create/).to_return(status: 200, headers: JSON_HEADERS, body: CONFIRMED)
    put = stub_request(:put, /storage\.example\.test/)
    with_setting(:app, :approvals, "allow") do
      %w[ put other ].each do |mode|
        @mode = mode
        upload @png, call_id: mode
        result = run_call(TOOL, arguments, call_id: mode)["result"]
        assert_match(/only POST uploads/, result["error"], mode)
        assert_no_match(/private|storage\.example\.test/, result.to_json)
      end
    end
    assert_not_requested outgoing
    assert_not_requested put
  end

  test "a file larger than Outline's advertised maximum never reaches storage" do
    @max_upload_size = @png.bytesize - 1
    outgoing = stub_request(:post, /\/api\/files\.create/).to_return(status: 200, headers: JSON_HEADERS, body: CONFIRMED)
    allow_and_approve("over-limit")
    result = run_call(TOOL, arguments, call_id: "over-limit")["result"]
    assert_match(/larger than wiki's upload limit/, result["error"])
    assert_not_requested outgoing
  end

  test "a different upload path is refused without posting the form to either host" do
    @upload_url = "#{PUBLIC}/api/users.info?sig=private"
    forbidden = stub_request(:post, /\/api\/users\.info/)
    allow_and_approve("bad-path")
    done = run_call(TOOL, arguments, call_id: "bad-path")
    assert_match(/isn't an upload/, done.dig("result", "error"))
    assert_not_includes done.to_json, "private"
    assert_not_requested forbidden
  end

  test "no file or a refused create result never reaches the upload endpoint" do
    outgoing = stub_request(:post, /\/api\/files\.create/)
    with_setting(:app, :approvals, "allow") do
      result = run_call(TOOL, arguments, call_id: "missing")["result"]
      assert_match(/dot\.png didn't arrive/, result["error"])
      assert_empty @created
      @answer_error = true
      upload @png, call_id: "refused"
      result = run_call(TOOL, arguments, call_id: "refused")["result"]
      assert_match(/couldn't prepare the upload/, result["error"])
      assert_not_includes result.to_json, "private body"
    end
    assert_not_requested outgoing
  end

  test "ask before every write still asks without Always even if everything is approved" do
    @connector.update!(asks_every_write: true)
    with_setting(:app, :approve_everything, true) do
      upload @png
      assert_equal "waiting", invoke(TOOL, arguments)["status"]
      perform_enqueued_jobs(only: InvocationPreviewJob)
      call = @conversation.invocations.sole.reload
      assert call.approvable?
      assert_empty call.always_choices
      assert_empty @created
    end
  end

  test "replacing the file after approval voids the approval before calling the wiki" do
    allow_and_approve("changed")
    upload "changed", call_id: "changed"
    run_call(TOOL, arguments, call_id: "changed")
    call = @conversation.invocations.sole.reload
    assert call.awaiting_person?
    assert_nil call.approval
    assert_equal [ "dot.png (7 Bytes)" ], call.preview["attachments"]
    assert_empty @created
  end

  private
    def png_chunk(type, data)
      [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
    end

    def stub_wiki(creates: true)
      tools = [ mcp_tool("fetch", annotations: { readOnlyHint: true }) ]
      tools << mcp_tool("create_attachment", annotations: { readOnlyHint: true }) if creates
      stub_mcp_server(url: @wiki, tools: tools, calls: {
        "fetch" => ->(args) { { structuredContent: @attachment.merge("id" => args["id"], "contentType" => "image/png", "signedUrl" => "#{PUBLIC}#{DOWNLOAD}") } },
        "create_attachment" => ->(args) {
          @created << args
          if @answer_error then { isError: true, content: [ { type: "text", text: "private body" } ] }
          else { content: [ { type: "text", text: upload_answer(args).to_json } ] }
          end
        }
      })
    end

    def form_fields(content_type = "image/png")
      { "Cache-Control" => "max-age=31557600", "Content-Type" => content_type, "key" => "uploads/u1/a1/dot.png", "acl" => "private",
        "maxUploadSize" => @max_upload_size.to_s, "contentType" => content_type, "sig" => "fake+signed/value=", "_csrf" => "" }
    end

    def upload_answer(args)
      attachment = @attachment.merge("userId" => "u1", "documentId" => nil, "contentType" => args["contentType"], "name" => args["name"])
      item = { mode: @mode, maxUploadSize: @max_upload_size, curlCommand: @curl, attachment: attachment }
      if @mode == "put"
        item.merge(url: "https://storage.example.test/private", headers: { "Content-Type" => args["contentType"] })
      else
        item.merge(uploadUrl: @upload_url, form: form_fields(args["contentType"]))
      end
    end

    # WebMock's Net::HTTP adapter does not serialize set_form. Use the real
    # wire request to check the multipart framing and stored bytes.
    def with_upload_response(status = "200 OK", headers = JSON_HEADERS, body = CONFIRMED)
      worker = Thread.new do
        socket = @socket.accept
        line = socket.gets.chomp
        fields = {}
        while (header = socket.gets) != "\r\n"
          name, value = header.split(":", 2)
          fields[name.downcase] = value.strip
        end
        bytes = socket.read(Integer(fields.fetch("content-length")))
        socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n")
        headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
        socket.write("\r\n#{body}")
        { line: line, headers: fields, body: bytes }
      ensure
        socket&.close
      end
      perform_enqueued_jobs(only: InvocationCallJob)
      assert worker.join(1), "the relay didn't post to the wiki's internal address"
      yield worker.value
    ensure
      worker&.kill&.join
    end

    def arguments = { "attachments" => [ PATH ] }

    def allow_and_approve(call_id, args = arguments)
      upload @png, call_id: call_id
      assert_response :no_content
      assert_equal "waiting", invoke(TOOL, args, call_id: call_id)["status"]
      perform_enqueued_jobs(only: InvocationPreviewJob)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @alice)
    end

    def upload(bytes, call_id: "toolu_1")
      payload = invocation_payload(@conversation, tool: TOOL, arguments: arguments, call_id: call_id).except(:arguments, :digest)
      post "/agent/uploads", params: payload.merge(path: PATH, bytes: Base64.strict_encode64(bytes)), headers: rails_bearer, as: :json
    end

    def invoke(tool, args, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: args, call_id: call_id), headers: rails_bearer, as: :json
      response.parsed_body
    end

    def run_call(tool, args, call_id:)
      invoke(tool, args, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(tool, args, call_id: call_id)
    end
end
