require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The phone's Share sheet: a post the operating system makes, which carries
# no CSRF token, is let in only as the browser marks it (Sec-Fetch-Site:
# none) and never from another site. It sends nothing: it asks which agent,
# or opens the only one's composer, filled in. What cannot go is said, and
# what was staged goes once sent or after a day.
class SharesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
  FROM_THE_SHARE_SHEET = { "Sec-Fetch-Site" => "none" }.freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Robin")
    @robin = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @iris = name_agent(@robin.agents.sole, "Iris")
  end
  teardown { remove_sidecar_settings }

  test "the Share sheet's post is let in without a token; another site's is refused" do
    with_forgery_protection do
      post shares_path, params: { text: "Lisbon in May" }, headers: FROM_THE_SHARE_SHEET
      assert_response :see_other
      assert_equal "Lisbon in May", @robin.shares.sole.text

      post shares_path, params: { text: "Send this" }, headers: { "Sec-Fetch-Site" => "cross-site", "Origin" => "https://elsewhere.example.com" }
      assert_response :unprocessable_entity
      post shares_path, params: { text: "Send this" }, headers: { "Sec-Fetch-Site" => "cross-site" }
      assert_response :unprocessable_entity
      assert_equal 1, @robin.shares.count
    end
  end

  test "the Share sheet's way in is for sharing alone: other forms still need their token" do
    with_forgery_protection do
      delete sign_out_path, headers: FROM_THE_SHARE_SHEET
      assert_response :unprocessable_entity
    end
  end

  test "with one agent, a share opens its composer with the words in the box and the picture attached, unsent" do
    post shares_path, params: { title: "Sintra", text: "Worth a day trip?", url: "https://travel.example.com/sintra",
                                files: [ picture ] }, headers: FROM_THE_SHARE_SHEET
    share = @robin.shares.sole
    assert_redirected_to conversation_path(@iris.conversation, share: share)
    assert_equal "Sintra\nWorth a day trip?\nhttps://travel.example.com/sintra", share.text
    assert_equal [ "sintra.png" ], share.files.map { it.filename.to_s }

    stub_request(:get, %r{#{SIDECAR}/v1/conversations}).to_return(status: 503, body: { error: "not_ready" }.to_json)
    @iris.conversation.update!(durable_id: "12")
    get conversation_path(@iris.conversation, share: share)
    assert_select "#composer textarea[name=content]", text: share.text
    assert_select "#composer input[type=hidden][name=share_id][value=?]", share.id.to_s
    assert_select "#composer [data-controller=shared-pictures][data-shared-pictures-files-value*=?]", "sintra.png"
    assert_not_requested :post, %r{#{SIDECAR}/v1/conversations/\d+/submissions}
  end

  test "with several agents, Share with… lists them, each opening its composer with the share" do
    sam = @robin.start_agent("Sam's errands")
    post shares_path, params: { text: "Milk, eggs" }, headers: FROM_THE_SHARE_SHEET
    share = @robin.shares.sole
    assert_redirected_to share_path(share)

    get share_path(share)
    assert_select "h1", "Share with…"
    assert_select ".share__text", "Milk, eggs"
    assert_select "a.share__agent[href=?]", conversation_path(@iris.conversation, share: share), text: /Iris/
    assert_select "a.share__agent[href=?]", conversation_path(sam.conversation, share: share), text: /Sam's errands/
  end

  test "a file the composer could not send is refused and named; a share of nothing goes nowhere" do
    post shares_path, params: { text: "Notes", files: [ picture("%PDF-1.7 not a picture", name: "itinerary.pdf"), picture(PNG + "x" * Conversation::IMAGE_BYTES, name: "huge.png") ] },
      headers: FROM_THE_SHARE_SHEET
    assert_equal "itinerary.pdf wasn't added: only pictures can be sent to an agent. huge.png wasn't added: each picture must be 5 MB or smaller.", flash[:alert]
    assert_empty @robin.shares.sole.files

    post shares_path, params: { files: (1..5).map { picture(name: "dot#{it}.png") } }, headers: FROM_THE_SHARE_SHEET
    assert_equal 4, @robin.shares.order(:id).last.files.count
    assert_match "dot5.png wasn't added: a message can carry up to 4 pictures.", flash[:alert]

    assert_no_difference -> { @robin.shares.count } do
      post shares_path, params: { files: [ picture("plain words", name: "notes.txt") ] }, headers: FROM_THE_SHARE_SHEET
    end
    assert_redirected_to root_path
    assert_match "notes.txt wasn't added", flash[:alert]
  end

  test "another person's share is not found" do
    sams = create_user(name: "Sam").shares.create!(text: "Private")
    get share_path(sams)
    assert_response :not_found

    stub_request(:get, %r{#{SIDECAR}/v1/conversations}).to_return(status: 503, body: { error: "not_ready" }.to_json)
    @iris.conversation.update!(durable_id: "12")
    get conversation_path(@iris.conversation, share: sams)
    assert_response :success
    assert_select "#composer textarea[name=content]", text: ""
    assert_select "#composer [name=share_id]", count: 0
  end

  test "signed out, a share goes to sign-in and asks to share again" do
    delete sign_out_path
    post shares_path, params: { text: "Lisbon" }, headers: FROM_THE_SHARE_SHEET
    assert_redirected_to sign_in_path
    follow_redirect!
    assert_select ".flash", text: /Sign in, then share again/
    assert_equal 0, Share.count # tenancy-ok: nobody is signed in; no share of anyone's was made
  end

  test "sending the message lets the staged pictures go; one never sent goes after a day" do
    sent = @robin.shares.create!(text: "Sent").tap { it.files.attach(io: StringIO.new(PNG), filename: "a.png", content_type: "image/png") }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    conversation = create_conversation(@iris)
    post conversation_submissions_path(conversation), params: { content: "Sent", request_id: "m-share", share_id: sent.id }, as: :turbo_stream
    assert_response :success
    assert_not Share.exists?(sent.id) # tenancy-ok: the share was the signed-in person's

    old = @robin.shares.create!(text: "Old", created_at: 25.hours.ago)
    fresh = @robin.shares.create!(text: "Fresh")
    ShareSweepJob.perform_now
    assert_equal [ fresh ], @robin.shares.reload.to_a
    assert_not Share.exists?(old.id) # tenancy-ok: the sweep is global
  end

  private
    def picture(bytes = PNG, name: "sintra.png") = Rack::Test::UploadedFile.new(StringIO.new(bytes), "image/png", original_filename: name)

    def with_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
end
