require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The canvas's pages: a document of the thread's agent, reached through the person.
class Conversations::DocumentsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent(name: "Maya")
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = @agent.conversation
    @document = @agent.documents.create!(title: "Trip plan").tap { it.revise("# Lisbon\n\nDay 1", by: "agent") }
  end

  test "the canvas shows the document in the thread's canvas frame, rendered, with its box and its history to load" do
    get conversation_document_path(@conversation, @document)

    assert_response :success
    assert_select "turbo-frame##{dom_id(@conversation, :canvas)} .canvas" do
      assert_select ".canvas__title", "Trip plan"
      assert_select ".canvas__page h1", "Lisbon"
      assert_select "textarea[name='document[body]']", text: "# Lisbon\n\nDay 1"
      assert_select "input[name=version_id][value=?]", @document.current_version.id.to_s
      assert_select "turbo-frame##{dom_id(@document, :versions)}[loading=lazy][src=?]", conversation_document_versions_path(@conversation, @document)
      assert_select "a.canvas__done[data-controller=canvas-done][href=?]", conversation_path(@conversation)
      assert_select "form[action=?] button[data-turbo-confirm]", conversation_document_deletion_path(@conversation, @document), text: "Delete"
    end
  end

  test "the documents list the agent's own, newest first, never another's or a deleted one, with New document and Recently deleted" do
    @agent.documents.create!(title: "Packing").tap { it.revise("- hat", by: "person") }.update_columns(updated_at: 1.day.ago)
    @agent.documents.create!(title: "Gone").tap { it.revise("x", by: "agent") }.soft_delete(by: "agent")
    create_user(name: "Robin").agents.sole.documents.create!(title: "Robin's").tap { it.revise("y", by: "agent") }

    get conversation_documents_path(@conversation)

    assert_response :success
    assert_select "turbo-frame##{dom_id(@conversation, :canvas)}[target=_top] .documents" do
      assert_equal [ "Trip plan", "Packing" ], css_select(".documents__item .documents__title").map(&:text)
      assert_select "a[href=?]", conversation_document_path(@conversation, @document), text: "Trip plan"
      assert_select ".documents__item", /Markdown · 15 characters/
      assert_select "a[href=?]", new_conversation_document_path(@conversation), text: "New document"
      assert_select "a[href=?]", conversation_deleted_documents_path(@conversation), text: "Recently deleted (1)"
      assert_select "a.canvas__done[href=?]", conversation_path(@conversation)
    end
  end

  test "a person makes a document, its title and body their first version, for the agent to see with their next message" do
    get new_conversation_document_path(@conversation)
    assert_select "form[action=?][method=post]", conversation_documents_path(@conversation) do
      assert_select "input[name='document[title]'][required]"
      assert_select "textarea[name='document[body]']"
    end

    post conversation_documents_path(@conversation), params: { document: { title: "  Packing  list ", body: "- hat\r\n- passport" } }

    document = @agent.documents.find_by!(title: "Packing list")
    assert_redirected_to conversation_document_path(@conversation, document)
    assert_equal [ 1, "person", "- hat\n- passport" ], document.current_version.then { [ it.number, it.author, it.body ] }
    assert document.changed_since_seen?

    post conversation_documents_path(@conversation), params: { document: { title: "Trip plan", body: "again" } }
    assert_response :unprocessable_entity
    assert_select ".canvas__problem", /Title has already been taken/
    assert_select "textarea[name='document[body]']", text: "again"
  end

  test "Delete deletes softly; Recently deleted lists it until the purge, and Restore brings it back" do
    post conversation_document_deletion_path(@conversation, @document)

    assert_redirected_to conversation_documents_path(@conversation)
    assert_equal "person", @document.reload.deleted_by
    get conversation_document_path(@conversation, @document)
    assert_response :not_found

    get conversation_deleted_documents_path(@conversation)
    assert_select ".documents__item", /Trip plan.*Deleted by you.*restore it until/m do
      assert_select "form[action=?] button", conversation_deleted_document_restoration_path(@conversation, @document), text: "Restore"
    end

    post conversation_deleted_document_restoration_path(@conversation, @document)

    assert_redirected_to conversation_document_path(@conversation, @document)
    assert_nil @document.reload.deleted_at
    get conversation_deleted_documents_path(@conversation)
    assert_select ".documents__item", 0
    assert_select ".documents__empty", /Nothing deleted/
  end

  test "nobody deletes, restores or makes a document outside their reach" do
    robin = create_user(name: "Robin").agents.sole
    theirs = robin.documents.create!(title: "Theirs").tap { it.revise("x", by: "agent") }
    gone = robin.documents.create!(title: "Gone").tap { it.revise("x", by: "agent") }.tap { it.soft_delete(by: "agent") }

    [ [ robin.conversation, theirs ], [ @conversation, theirs ] ].each do |conversation, document|
      post conversation_document_deletion_path(conversation, document)
      assert_response :not_found
    end
    [ [ robin.conversation, gone ], [ @conversation, gone ], [ @conversation, @document ] ].each do |conversation, document|
      post conversation_deleted_document_restoration_path(conversation, document)
      assert_response :not_found
    end
    get conversation_deleted_documents_path(robin.conversation)
    assert_response :not_found
    post conversation_documents_path(robin.conversation), params: { document: { title: "Mine", body: "x" } }
    assert_response :not_found

    assert_nil theirs.reload.deleted_at
    assert gone.reload.deleted_at
    assert_equal [ "Gone", "Theirs" ], Document.where(agent: robin).order(:title).pluck(:title) # tenancy-ok: the test reads Robin's agent's
  end

  test "another person's document, or one of another agent, is not found" do
    robin = create_user(name: "Robin").agents.sole
    theirs = robin.documents.create!(title: "Theirs").tap { it.revise("x", by: "agent") }

    get conversation_document_path(robin.conversation, theirs)
    assert_response :not_found
    get conversation_document_path(@conversation, theirs)
    assert_response :not_found
    patch conversation_document_path(@conversation, theirs), params: { document: { body: "mine now" }, version_id: theirs.current_version.id }
    assert_response :not_found
    get conversation_document_download_path(@conversation, theirs)
    assert_response :not_found
    assert_equal "x", theirs.reload.body
  end

  test "saving writes the person's version, which the agent has not seen yet" do
    patch conversation_document_path(@conversation, @document), params: { document: { body: "# Lisbon\r\n\r\nDay 1: Belém" }, version_id: @document.current_version.id }

    assert_redirected_to conversation_document_path(@conversation, @document)
    assert_equal [ 2, "person", "# Lisbon\n\nDay 1: Belém" ], @document.reload.current_version.then { [ it.number, it.author, it.body ] }
    assert @document.changed_since_seen?
  end

  test "a save from a box the agent has written over since keeps the person's words and saves nothing" do
    base = @document.current_version.id
    @document.revise("# Lisbon\n\nDay 1: Alfama", by: "agent")

    patch conversation_document_path(@conversation, @document), params: { document: { body: "Mine" }, version_id: base }

    assert_response :conflict
    assert_select ".canvas__problem", /changed this while you were editing/
    assert_select "textarea[name='document[body]']", text: "Mine"
    assert_select "input[name=version_id][value=?]", @document.current_version.id.to_s
    assert_select "input[data-mode=edit][checked]"
    assert_equal 2, @document.reload.number
  end

  test "the history lists every version, newest first, and restoring one makes it current again as the person's" do
    first = @document.current_version
    @document.revise("Rewritten", by: "agent")

    get conversation_document_versions_path(@conversation, @document)
    assert_select "turbo-frame##{dom_id(@document, :versions)} .canvas__history li", 2
    assert_select ".canvas__history li:first-child", /Version 2.*Current/m
    assert_select ".canvas__history li:last-child form[data-turbo-frame=?] button", dom_id(@conversation, :canvas), text: "Restore"

    post conversation_document_restorations_path(@conversation, @document), params: { version_id: first.id }
    assert_redirected_to conversation_document_path(@conversation, @document)
    assert_equal [ 3, "person", first.body ], @document.reload.current_version.then { [ it.number, it.author, it.body ] }
  end

  test "Download gives the source exactly, named for its kind" do
    @document.update!(kind: "code", language: "python")
    @document.revise("print('hi')\n", by: "agent")

    get conversation_document_download_path(@conversation, @document)

    assert_response :success
    assert_equal "print('hi')\n", response.body
    assert_equal "text/plain; charset=utf-8", response.media_type + "; charset=" + response.charset
    assert_match(/\Aattachment; filename="trip-plan.py"/, response.headers["Content-Disposition"])
  end

  test "a web page is code, shown as its escaped source: nothing in it runs or loads" do
    @document.update!(kind: "code", language: "html")
    @document.revise(%(<h1>Hi</h1><img src="https://example.com/a.png"><script>fetch("https://example.com")</script>), by: "agent")

    get conversation_document_path(@conversation, @document)

    assert_select "iframe", 0
    assert_select ".canvas__page h1", 0
    assert_select ".canvas__page img", 0
    assert_select ".canvas__page script", 0
    assert_select ".canvas__page pre code", /<script>fetch/
  end

  test "the thread's card for a document the agent wrote opens it in the canvas frame" do
    conversation = create_conversation(@agent)
    payload = invocation_payload(conversation, tool: "write_document", arguments: { "title" => "Packing", "body" => "- hat" })
    Invocation.receive(conversation, task_id: 7, call_id: "toolu_1", tool: "write_document", arguments: payload[:arguments], digest: payload[:digest])
    install_sidecar_settings
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [
      { id: "1", entryId: 1, role: "assistant", content: "[tool: write_document]", toolCalls: [ { id: "toolu_1", name: "write_document" } ] }
    ], cursor: 1, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)

    get conversation_path(conversation)

    assert_select "turbo-frame##{dom_id(conversation, :canvas)}.canvas-frame[data-turbo-permanent]"
    assert_select ".document-card", /Packing.*Wrote · Markdown/m do
      assert_select "a[data-turbo-frame=?][href=?]", dom_id(conversation, :canvas), conversation_document_path(conversation, @agent.documents.find_by!(title: "Packing")), text: "Open"
    end
  ensure
    remove_sidecar_settings
  end

  private
    def dom_id(...) = ActionView::RecordIdentifier.dom_id(...)
end
