require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A file a person attaches in the thread (Conversation::Attachments,
# docs/agent.md, "Files a person attaches"): kept with their message, saved on the
# agent's computer under ~/files as a mailed file is (Conversation::Handover,
# agent/files.mjs), and named, with where it was saved, in the words the agent
# reads. WebMock stands in for the sidecar, which fetches each file back from
# POST /agent/files, as it does here.
class ComposerFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  DOCX = "PK\x03\x04".b + Random.new(11).bytes(12_000)
  FOLDER = "/home/agent/files/5e6f7a8b9c"
  WORD = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the person the test signed in
    @conversation = create_conversation(@agent)
    @agent.create_computer!(provider: "sprites", state: "on")
    @submissions, @saves, @entries = [], [], []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return { { body: { entries: @entries, cursor: nil, more: false }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12(\?|\z)}).to_return(status: 503, body: { error: "not_ready" }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/files").to_return { |request|
      @saves << JSON.parse(request.body)
      { status: 200, body: { files: @saves.last["files"].map { it.merge("saved" => "#{FOLDER}/#{it["name"]}") } }.to_json } }
  end
  teardown { remove_sidecar_settings }

  test "a .docx attached to a message is saved on the agent's computer, its path named in what the agent reads, and kept with the message" do
    post conversation_submissions_path(@conversation), params: { content: "Notes from today", request_id: "m-docx",
      files: [ upload(DOCX, WORD, "Q3 plan.docx") ] }, as: :turbo_stream
    assert_response :success
    assert_select "turbo-stream[action=append]", 0, "the queued send has no committed bubble yet"

    save = @saves.sole
    assert_equal @agent.computer.descriptor.as_json, save["computer"]
    assert_equal [ { "name" => "Q3 plan.docx", "type" => WORD, "size" => DOCX.bytesize, "held" => 0 } ], save["files"]
    post "/agent/files", params: fetch(save, index: 0), headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal DOCX, response.body.b, "the sidecar reads the file's bytes back, whole"

    sent = words(@submissions.sole["content"])
    assert_kind_of String, sent, "a file goes as words, not as a block the model must read"
    assert_match "Notes from today", sent
    assert_match "- Q3 plan.docx (#{WORD}, 11.7 KB): saved at #{FOLDER}/Q3 plan.docx", sent

    @entries << { "id" => "e-1", "entryId" => 1, "role" => "user", "content" => @submissions.sole["content"], "requestId" => "m-docx",
      "author" => { "userId" => @agent.user_id.to_s } }
    @conversation.sync!
    message = @conversation.messages.sole
    assert_equal [ "Q3 plan.docx" ], message.files.map { it.filename.to_s }
    assert_equal DOCX, message.files.sole.download
    assert_equal "Notes from today", message.said, "the person's bubble shows their words; the list is the agent's"

    get conversation_path(@conversation)
    assert_select ".ui-files a[href=?]", rails_blob_path(message.files.sole, disposition: :attachment, only_path: true) do
      assert_select ".ui-files__name", "Q3 plan.docx"
      assert_select ".ui-files__size", "11.7 KB"
    end
  end

  test "the Turbo response carries the committed file chip even without live updates" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return do |request|
      sent = JSON.parse(request.body)
      author = { userId: @agent.user_id.to_s }
      @entries = [
        { id: "e-1", entryId: 1, role: "user", content: "Earlier", requestId: "m-earlier", author: author },
        { id: "e-2", entryId: 2, role: "user", content: sent["content"], requestId: sent["requestId"], author: author }
      ]
      { status: 202, body: { id: 2, status: "running" }.to_json }
    end

    post conversation_submissions_path(@conversation), params: { content: "Notes from today", request_id: "m-docx",
      files: [ upload(DOCX, WORD, "Q3 plan.docx") ] }, as: :turbo_stream

    assert_response :success
    message = @conversation.messages.find_by!(request_id: "m-docx")
    assert_select "turbo-stream[action=append]", count: 1 do |streams|
      assert_equal "#messages[data-conversation-id='#{@conversation.id}']", streams.sole["targets"]
      assert_select "template > article", count: 1
      assert_select "#message_#{message.id} .ui-files a[href=?]", rails_blob_path(message.files.sole, disposition: :attachment, only_path: true) do
        assert_select ".ui-files__name", "Q3 plan.docx"
      end
    end
  end

  test "a PDF and a .zip sent together: both reach the agent's computer and its words, and the message shows each by name and size" do
    pdf = "%PDF-1.4\n".b + Random.new(5).bytes(40_000)
    zip = "PK\x03\x04".b + Random.new(7).bytes(300_000)
    post conversation_submissions_path(@conversation), params: { content: "Contract and the photos", request_id: "m-pdf-zip",
      files: [ upload(pdf, "application/pdf", "Lease 2026.pdf"), upload(zip, "application/zip", "site photos.zip") ] }, as: :turbo_stream
    assert_response :success

    save = @saves.sole
    assert_equal [ { "name" => "Lease 2026.pdf", "type" => "application/pdf", "size" => pdf.bytesize, "held" => 0 },
      { "name" => "site photos.zip", "type" => "application/zip", "size" => zip.bytesize, "held" => 1 } ], save["files"]
    [ pdf, zip ].each_with_index do |bytes, index|
      post "/agent/files", params: fetch(save, index: index), headers: rails_bearer, as: :json
      assert_equal bytes, response.body.b
    end
    sent = words(@submissions.sole["content"])
    assert_match "- Lease 2026.pdf (application/pdf, 39.1 KB): saved at #{FOLDER}/Lease 2026.pdf", sent
    assert_match "- site photos.zip (application/zip, 293 KB): saved at #{FOLDER}/site photos.zip", sent

    @entries << { "id" => "e-1", "entryId" => 1, "role" => "user", "content" => @submissions.sole["content"], "requestId" => "m-pdf-zip",
      "author" => { "userId" => @agent.user_id.to_s } }
    @conversation.sync!
    get conversation_path(@conversation)
    assert_select "[data-role=user] .ui-files .ui-files__file", 2
    assert_select "[data-role=user] .ui-files .ui-files__file" do |links|
      assert_equal [ "Lease 2026.pdf", "site photos.zip" ], links.map { it.at_css(".ui-files__name").text }
      assert_equal [ "39.1 KB", "293 KB" ], links.map { it.at_css(".ui-files__size").text }
    end
  end

  test "a file alone is a message, and pictures with it still go as pictures" do
    png = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
    post conversation_submissions_path(@conversation), params: { request_id: "m-both",
      images: [ upload(png, "image/png", "dot.png") ], files: [ upload("%PDF-1.4\n".b, "application/pdf", "brief.pdf") ] }, as: :turbo_stream

    assert_response :success
    content = @submissions.sole["content"]
    assert_equal %w[ text image ], content.pluck("type")
    assert_match "- brief.pdf (application/pdf, 9 Bytes): saved at #{FOLDER}/brief.pdf", content.first["text"]
  end

  test "a file over the limit is refused in the composer, in plain words, and nothing is saved or sent" do
    big = upload("\0".b * (Conversation::FILE_BYTES + 1), "application/pdf", "scan.pdf")
    post conversation_submissions_path(@conversation), params: { content: "Here", request_id: "m-big", files: [ big ] }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_select "turbo-stream[action=update][target=composer_error] template", "scan.pdf is over 25 MB: each file must be 25 MB or smaller."
    assert_empty @saves
    assert_empty @submissions
  end

  test "the same send again is not saved twice" do
    2.times do
      post conversation_submissions_path(@conversation), params: { content: "Again", request_id: "m-again",
        files: [ upload(DOCX, WORD, "Q3 plan.docx") ] }, as: :turbo_stream
    end

    assert_equal 1, @saves.size
  end

  private
    def upload(bytes, type, name) = Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)

    def fetch(save, index:)
      { actorId: save["actorId"], workspaceId: save["workspaceId"], conversationId: "12", taskId: save["taskId"], callId: save["callId"], index: index }
    end
end
