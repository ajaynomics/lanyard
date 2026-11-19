require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A file a Google tool found (docs/connectors.md): the call answers with what
# the file is and says there is one; the sidecar then fetches its bytes once,
# soon after, to save on the agent's computer. The bytes are never in the
# ledger, and only Google's file tools can be fetched this way.
class GoogleFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  DRIVE = "https://www.googleapis.com/drive/v3".freeze
  PDF = "%PDF-1.7\n\xE2\xE3\xCF\xD3 binary".b.freeze
  DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document".freeze
  XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze
  PPTX = "application/vnd.openxmlformats-officedocument.presentationml.presentation".freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    stub_request(:get, "#{GMAIL}/messages/m1").with(query: { format: "full" }).to_return(json(id: "m1", payload: {
      mimeType: "multipart/mixed", parts: [ { partId: "0", mimeType: "text/plain", filename: "", body: { data: Base64.urlsafe_encode64("Hi") } },
        { partId: "1", mimeType: "application/pdf", filename: "../Plan\u0000.pdf", body: { attachmentId: "ANGjdJ-changes-each-read", size: PDF.bytesize } } ] }))
    @bytes = stub_request(:get, "#{GMAIL}/messages/m1/attachments/ANGjdJ-changes-each-read").to_return(json(size: PDF.bytesize, data: Base64.urlsafe_encode64(PDF)))
  end
  teardown { remove_sidecar_settings }

  test "an attachment is named and sized in the ledger, and its bytes go to the sidecar once asked, never into the ledger" do
    connector("gmail")
    done = run_call("mcp__gmail__get_attachment", { "message_id" => "m1", "attachment_id" => "1" })

    assert_equal true, done["file"]
    assert_equal({ "name" => "Plan.pdf", "type" => "application/pdf", "size" => PDF.bytesize }, done.dig("result", "file"))
    assert_not_requested @bytes

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PDF, response.body.b
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not_includes @conversation.invocations.sole.attributes.to_json, Base64.urlsafe_encode64(PDF)
  end

  test "a file can be fetched only soon after its call, only with RAILS_TOKEN, and only from a Google file tool" do
    connector("gmail")
    run_call("mcp__gmail__get_attachment", { "message_id" => "m1", "attachment_id" => "1" })

    post "/agent/files", params: fetch, headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
    travel Invocation::FILE_WITHIN + 1.minute do
      post "/agent/files", params: fetch, headers: rails_bearer, as: :json
      assert_response :gone
    end

    stub_request(:get, "#{GMAIL}/messages/m1").with(query: { format: "full" }).to_return(json(id: "m1", payload: {}))
    listed = run_call("mcp__gmail__get_message", { "message_id" => "m1" }, call_id: "toolu_2")
    assert_nil listed["file"]
    post "/agent/files", params: fetch(call_id: "toolu_2"), headers: rails_bearer, as: :json
    assert_response :gone
  end

  test "a Drive PDF is fetched as bytes, as it is" do
    connector("drive")
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
      .to_return(json(id: "f1", name: "Report.pdf", mimeType: "application/pdf", size: PDF.bytesize.to_s))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: "application/pdf"))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(alt: "media")).to_return(body: PDF)

    done = run_call("mcp__drive__read_file", { "file_id" => "f1" })
    assert_equal true, done["file"]
    assert_equal "Report.pdf", done.dig("result", "file", "name")

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PDF, response.body.b
  end

  BIG = 30.megabytes

  test "a 30 MB Drive PDF reaches the sidecar whole, streamed from a file on disk rather than held in memory" do
    connector("drive")
    big = "%PDF-1.7\n".b + ("\xE2\xE3\xCF\xD3".b * (BIG / 4))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
      .to_return(json(id: "f1", name: "Package.pdf", mimeType: "application/pdf", size: big.bytesize.to_s))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: "application/pdf"))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(alt: "media")).to_return(body: big)

    done = run_call("mcp__drive__read_file", { "file_id" => "f1" })
    assert_equal true, done["file"], done["result"].to_s
    assert_equal({ "name" => "Package.pdf", "type" => "application/pdf", "size" => big.bytesize }, done.dig("result", "file"))
    with_google_app { assert_respond_to @conversation.invocations.sole.download_file, :path, "a Drive file waits on disk" }

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal big.bytesize.to_s, response.headers["Content-Length"]
    assert_equal Digest::SHA256.hexdigest(big), Digest::SHA256.hexdigest(response.body.b)
  end

  test "a 30 MB Gmail attachment is offered to save and reaches the sidecar whole" do
    big = Random.new(1).bytes(BIG)
    stub_request(:get, "#{GMAIL}/messages/m2").with(query: { format: "full" }).to_return(json(id: "m2", payload: {
      mimeType: "multipart/mixed", parts: [ { partId: "1", mimeType: "application/zip", filename: "Package.zip", body: { attachmentId: "A2", size: big.bytesize } } ] }))
    stub_request(:get, "#{GMAIL}/messages/m2/attachments/A2").to_return(json(size: big.bytesize, data: Base64.urlsafe_encode64(big)))
    connector("gmail")

    done = run_call("mcp__gmail__get_attachment", { "message_id" => "m2", "attachment_id" => "1" })
    assert_equal true, done["file"], done["result"].to_s
    assert_nil done.dig("result", "note")
    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal Digest::SHA256.hexdigest(big), Digest::SHA256.hexdigest(response.body.b)
  end

  test "a Doc longer than READ_BYTES is saved whole on the computer, and the model reads its start" do
    connector("drive")
    long = Array.new(20_000) { "Paragraph #{it} of the plan." }.join("\n\n")
    assert_operator long.bytesize, :>, 2 * DurableAssistants::Google::Drive::READ_BYTES
    stub_request(:get, "#{DRIVE}/files/d1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
      .to_return(json(id: "d1", name: "Plan/2026", mimeType: "application/vnd.google-apps.document"))
    stub_request(:get, "#{DRIVE}/files/d1").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: "application/vnd.google-apps.document"))
    export = stub_request(:get, "#{DRIVE}/files/d1/export").with(query: { mimeType: "text/markdown" }).to_return(body: long)

    done = run_call("mcp__drive__read_file", { "file_id" => "d1" })
    assert_equal true, done["file"]
    result = done["result"]
    assert long.start_with?(result["text"])
    assert_operator JSON.generate(result["text"]).bytesize, :<=, DurableAssistants::Google::Drive::READ_BYTES
    assert_operator result["text"].length, :>, 35_000
    assert_equal true, result["truncated"]
    assert_equal({ "name" => "2026.md", "type" => "text/markdown", "size" => long.bytesize }, result["file"])
    assert_match "whole file is saved", result["note"]

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal long, response.body.force_encoding(Encoding::UTF_8)
    assert_requested export, times: 2
  end

  test "a Doc in a script of three bytes a character, under 40,000 characters but over the sidecar's bytes, is saved whole too" do
    connector("drive")
    long = "計画の段落です。" * 3_000
    assert_operator long.length, :<, 40_000
    assert_operator long.bytesize, :>, 51_200
    stub_request(:get, "#{DRIVE}/files/d1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
      .to_return(json(id: "d1", name: "計画", mimeType: "application/vnd.google-apps.document"))
    stub_request(:get, "#{DRIVE}/files/d1").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: "application/vnd.google-apps.document"))
    stub_request(:get, "#{DRIVE}/files/d1/export").with(query: { mimeType: "text/markdown" }).to_return(body: long)

    done = run_call("mcp__drive__read_file", { "file_id" => "d1" })
    assert_equal true, done["file"]
    result = done["result"]
    assert long.start_with?(result["text"])
    assert_operator JSON.generate(result).bytesize, :<, 48_000, "what the model reads fits the sidecar's limit"
    assert_equal({ "name" => "計画.md", "type" => "text/markdown", "size" => long.bytesize }, result["file"])

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_equal long, response.body.force_encoding(Encoding::UTF_8)
  end

  test "a text file over DOWNLOAD_LIMIT is saved whole on the computer, not read into the answer" do
    connector("drive")
    big = "line of the log\n" * (DurableAssistants::Google::Drive::DOWNLOAD_LIMIT / 16 + 1)
    stub_request(:get, "#{DRIVE}/files/t1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
      .to_return(json(id: "t1", name: "server.log", mimeType: "text/plain", size: big.bytesize.to_s))
    stub_request(:get, "#{DRIVE}/files/t1").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: "text/plain"))
    media = stub_request(:get, "#{DRIVE}/files/t1").with(query: hash_including(alt: "media")).to_return(body: big)

    done = run_call("mcp__drive__read_file", { "file_id" => "t1" })
    assert_equal true, done["file"]
    assert_equal({ "name" => "server.log", "type" => "text/plain", "size" => big.bytesize }, done.dig("result", "file"))
    assert_nil done.dig("result", "text")
    assert_not_requested media

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal big, response.body
  end

  test "a Word file from Drive is saved on the computer and its words come back" do
    connector("drive")
    docx = office("word/document.xml" => <<~XML)
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>Budget for </w:t></w:r><w:r><w:t>Thursday</w:t></w:r></w:p><w:p><w:r><w:t>Rooms: 4</w:t></w:r></w:p>
      </w:body></w:document>
    XML
    drive_file("w1", "Budget.docx", DOCX, docx)

    done = run_call("mcp__drive__read_file", { "file_id" => "w1" })
    assert_equal true, done["file"]
    assert_equal({ "name" => "Budget.docx", "type" => DOCX, "size" => docx.bytesize }, done.dig("result", "file"))
    assert_equal "Budget for Thursday\nRooms: 4", done.dig("result", "text")
    assert_match "saved on your computer", done.dig("result", "note")

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_equal docx, response.body.b
  end

  test "a Sheet and Slides from Office come back as their words too" do
    connector("drive")
    xlsx = office("xl/sharedStrings.xml" => '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Item</t></si><si><t>Rooms</t></si></sst>',
      "xl/worksheets/sheet1.xml" => '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' \
        '<row><c t="s"><v>0</v></c><c t="inlineStr"><is><t>Cost</t></is></c></row><row><c t="s"><v>1</v></c><c><v>120</v></c></row></sheetData></worksheet>')
    pptx = office("ppt/slides/slide10.xml" => slide("Last"), "ppt/slides/slide2.xml" => slide("Middle"), "ppt/slides/slide1.xml" => slide("First"))
    drive_file("x1", "Costs.xlsx", XLSX, xlsx)
    assert_equal "Item\tCost\nRooms\t120", run_call("mcp__drive__read_file", { "file_id" => "x1" }).dig("result", "text")
    drive_file("s1", "Talk.pptx", PPTX, pptx)
    assert_equal "Slide 1\nFirst\n\nSlide 2\nMiddle\n\nSlide 3\nLast", run_call("mcp__drive__read_file", { "file_id" => "s1" }, call_id: "toolu_2").dig("result", "text")
  end

  test "a file of a kind that can't be read as text is still saved, and the note says where" do
    connector("drive")
    zip = office("a.txt" => "anything")
    drive_file("z1", "Photos.zip", "application/zip", zip)

    done = run_call("mcp__drive__read_file", { "file_id" => "z1" })
    assert_equal true, done["file"]
    assert_equal({ "name" => "Photos.zip", "type" => "application/zip", "size" => zip.bytesize }, done.dig("result", "file"))
    assert_nil done.dig("result", "text")
    assert_match "saved on your computer", done.dig("result", "note")

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_equal zip, response.body.b
  end

  test "a Google Doc asked for as docx or pdf is exported and saved as that file" do
    connector("drive")
    doc = "application/vnd.google-apps.document"
    stub_request(:get, "#{DRIVE}/files/d1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS)).to_return(json(id: "d1", name: "Plan", mimeType: doc))
    stub_request(:get, "#{DRIVE}/files/d1").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: doc))
    docx = office("word/document.xml" => "<document/>")
    stub_request(:get, "#{DRIVE}/files/d1/export").with(query: { mimeType: DOCX }).to_return(body: docx)
    stub_request(:get, "#{DRIVE}/files/d1/export").with(query: { mimeType: "application/pdf" }).to_return(body: PDF)

    done = run_call("mcp__drive__read_file", { "file_id" => "d1", "format" => "docx" })
    assert_equal true, done["file"]
    assert_equal "Plan.docx", done.dig("result", "file", "name")
    assert_match "saved on your computer", done.dig("result", "note")
    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_equal docx, response.body.b

    done = run_call("mcp__drive__read_file", { "file_id" => "d1", "format" => "pdf" }, call_id: "toolu_2")
    assert_equal({ "name" => "Plan.pdf", "type" => "application/pdf" }, done.dig("result", "file").slice("name", "type"))
    post "/agent/files", params: fetch(call_id: "toolu_2"), headers: rails_bearer, as: :json
    assert_equal PDF, response.body.b
  end

  private
    def office(entries) = Zip::OutputStream.write_buffer(StringIO.new) { |zip| entries.each { |name, body| zip.put_next_entry(name); zip.write(body) } }.string.b

    def slide(words) = %(<p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>#{words}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>)

    def drive_file(id, name, type, bytes)
      stub_request(:get, "#{DRIVE}/files/#{id}").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
        .to_return(json(id: id, name: name, mimeType: type, size: bytes.bytesize.to_s))
      stub_request(:get, "#{DRIVE}/files/#{id}").with(query: hash_including(fields: "mimeType")).to_return(json(mimeType: type))
      stub_request(:get, "#{DRIVE}/files/#{id}").with(query: hash_including(alt: "media")).to_return(body: bytes)
    end

    def run_call(tool, arguments, call_id: "toolu_1")
      with_google_app do
        invoke(tool, arguments, call_id)
        perform_enqueued_jobs(only: InvocationCallJob)
        invoke(tool, arguments, call_id)
      end
    end

    def invoke(tool, arguments, call_id)
      @last = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      post "/agent/invocations", params: @last, headers: rails_bearer, as: :json
      response.parsed_body
    end

    def fetch(call_id: "toolu_1")
      { actorId: @last[:actorId], workspaceId: @last[:workspaceId], conversationId: @last[:conversationId], taskId: @last[:taskId], callId: call_id }
    end

    def connector(kind)
      with_google_app do
        @alice.mcp_servers.create!(name: kind, **McpServer.gallery_attributes(kind), refreshed_at: Time.current,
          oauth_tokens: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => 1.hour.from_now.to_i })
      end
    end

    def with_google_app
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
      yield
    ensure
      x.connectors = saved
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
end
