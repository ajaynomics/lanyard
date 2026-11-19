require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# These are controller contracts for typed model refusals, not tests of the
# model's size or replay rules. Nothing is sent on a refused HTML redirect.
class SubmissionRefusalsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
  REFUSALS = {
    "too_large" => [ Conversation::Submission::TooLarge, 422 ],
    "conflict" => [ Conversation::Submission::Conflict, 409 ],
    "refused" => [ Conversation::ImagesRefused, 422 ]
  }.freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the signed-in person
    @conversation = create_conversation(@user.agents.sole)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "not_ready" }.to_json)
  end
  teardown { remove_sidecar_settings }

  REFUSALS.each do |error, (type, status)|
    test "#{error} is truthful JSON with status #{status}" do
      refusal = refusal_for(type)
      with_refusal(refusal) do
        assert_no_difference -> { @user.shares.count } do
          post conversation_submissions_path(@conversation), params: { content: "Keep this", request_id: "same-json" }, as: :json
        end
      end
      assert_response status
      assert_equal({ "error" => error, "message" => refusal.message }, response.parsed_body)
    end

    test "#{error} only updates the Turbo draft error without replacing the request id" do
      refusal = refusal_for(type)
      with_refusal(refusal) do
        assert_no_difference -> { @user.shares.count } do
          post conversation_submissions_path(@conversation), params: { content: "Keep this", request_id: "same-turbo", images: [ picture ] }, as: :turbo_stream
        end
      end
      assert_response status
      assert_select "turbo-stream", count: 1
      assert_select "turbo-stream[action=update][target=composer_error] template", text: refusal.message
      assert_select "input[name=request_id]", count: 0
      assert_select "turbo-stream[target=composer_request_id]", count: 0
      assert_select "turbo-stream[target=composer]", count: 0
    end

    test "#{error} stages the exact HTML draft and full picture with the original id, unsent on reload" do
      refusal = refusal_for(type)
      # Above the Share sheet's truncation limit, below the raw input limit;
      # whitespace, Unicode and HTML characters must all survive unchanged.
      text = "  <draft>&é\n" + "é" * 31_000 + "\n  "
      share = nil
      with_refusal(refusal) do |attempts|
        assert_difference -> { @user.shares.count }, 1 do
          post conversation_submissions_path(@conversation), params: { content: text, request_id: "same-html", images: [ picture ] }
        end
        share = @user.shares.sole
        assert_redirected_to conversation_path(@conversation, share: share)
        assert_equal refusal.message, flash[:alert]
        assert_equal text.bytes, share.text.bytes
        assert_equal "same-html", share.submission_request_id
        assert_equal PNG, share.files.sole.download
        assert_equal "draft.png", share.files.sole.filename.to_s
        assert_equal "image/png", share.files.sole.content_type

        2.times do
          get conversation_path(@conversation, share: share)
          assert_response :success
          assert_equal text, css_select("#composer textarea[name=content]").sole.text
          assert_select "#composer input[name=request_id][value=same-html]", count: 1
          assert_select "#composer input[name=share_id][value=?]", share.id.to_s
          assert_select "#composer [data-controller=shared-pictures][data-shared-pictures-files-value*=?]", "draft.png"
        end
        assert_equal 1, attempts.size, "opening or reloading a staged draft must not submit it"
      end
      assert_not_requested :post, %r{#{SIDECAR}/v1/conversations/\d+/submissions}

      outsider = create_user(name: "Outsider")
      sign_in_via_ajent(subject: outsider.oidc_sub)
      get share_path(share)
      assert_response :not_found
      outsider.conversations.sole.update!(durable_id: "13")
      stub_request(:get, %r{#{SIDECAR}/v1/conversations/13}).to_return(status: 503, body: { error: "not_ready" }.to_json)
      get conversation_path(outsider.conversations.sole, share: share)
      assert_response :success
      assert_select "#composer textarea[name=content]", text: ""
      assert_select "#composer input[name=share_id]", count: 0
      assert_select "#composer input[name=request_id][value=same-html]", count: 0
    end
  end

  test "a failed HTML send never overwrites or deletes an existing share and keeps every valid upload" do
    original = @user.shares.create!(text: "Earlier draft", submission_request_id: "earlier-id")
    original.files.attach(io: StringIO.new(PNG), filename: "earlier.png", content_type: "image/png")
    with_refusal(Conversation::ImagesRefused.new("Only pictures can be sent.")) do
      post conversation_submissions_path(@conversation), params: { content: "Actual text  ", request_id: "failed-id", share_id: original.id,
        images: [ picture("not a picture", name: "notes.txt"), picture(name: "first.png"), picture(name: "second.png") ] }
    end
    assert_response :see_other
    assert_equal "Only pictures can be sent. notes.txt wasn't added: only pictures can be sent to an agent.", flash[:alert]
    assert_equal "Earlier draft", original.reload.text
    assert_equal "earlier-id", original.submission_request_id
    assert_equal PNG, original.files.sole.download
    staged = @user.shares.where.not(id: original.id).sole
    assert_equal "Actual text  ", staged.text
    assert_equal "failed-id", staged.submission_request_id
    assert_equal [ "first.png", "second.png" ], staged.files.map { it.filename.to_s }
    assert_equal [ PNG, PNG ], staged.files.map(&:download)
  end

  test "an image-only failed HTML send retains the picture and original request id" do
    with_refusal(Conversation::Submission::Conflict.new) do
      post conversation_submissions_path(@conversation), params: { request_id: "picture-id", images: [ picture ] }
    end
    share = @user.shares.sole
    assert_equal "", share.text
    assert_equal "picture-id", share.submission_request_id
    assert_equal PNG, share.files.sole.download
    assert_redirected_to conversation_path(@conversation, share: share)
  end

  test "the Watch receives typed JSON refusals, and its token cannot send to another person's agent" do
    post watches_path, params: { name: "Test Watch" }, as: :json
    assert_response :created
    token = response.parsed_body.fetch("token")
    delete sign_out_path
    headers = { "Authorization" => "Bearer #{token}" }

    REFUSALS.except("refused").each do |error, (type, status)|
      refusal = refusal_for(type)
      with_refusal(refusal) do |attempts|
        post conversation_submissions_path(@conversation), params: { content: "Watch draft", request_id: "watch-id" }, as: :json, headers: headers
        assert_response status
        assert_equal({ "error" => error, "message" => refusal.message }, response.parsed_body)
        assert_equal [ @conversation.id ], attempts
      end
    end

    outsider = create_user(name: "Outsider")
    with_refusal(Conversation::Submission::Conflict.new) do |attempts|
      post conversation_submissions_path(outsider.conversations.sole), params: { content: "No", request_id: "watch-id" }, as: :json, headers: headers
      assert_response :not_found
      assert_empty attempts
    end
  end

  test "successful Turbo sends remove the failed draft and renew the request id" do
    share = @user.shares.create!(text: "Edited", submission_request_id: "accepted-id")
    stub_acceptance
    post conversation_submissions_path(@conversation), params: { content: "Edited", request_id: "accepted-id", share_id: share.id }, as: :turbo_stream
    assert_response :success
    assert_empty @user.shares.reload
    assert_select "turbo-stream[action=replace][target=composer_request_id] input[name=request_id]" do |fields|
      assert Agent::Access.valid_id?(fields.sole["value"])
      assert_not_equal "accepted-id", fields.sole["value"]
    end
  end

  test "successful JSON still returns an acceptance receipt for the submitted id" do
    stub_acceptance
    post conversation_submissions_path(@conversation), params: { content: "Hello", request_id: "json-ok" }, as: :json
    assert_response :accepted
    assert_equal({ "conversation_id" => @conversation.id, "request_id" => "json-ok", "accepted" => true }, response.parsed_body)
  end

  private
    def picture(bytes = PNG, name: "draft.png")
      Rack::Test::UploadedFile.new(StringIO.new(bytes), "image/png", original_filename: name)
    end

    def refusal_for(type)
      type == Conversation::ImagesRefused ? type.new("The model cannot look at pictures.") : type.new
    end

    def with_refusal(refusal)
      attempts = []
      original = Conversation.instance_method(:submit)
      Conversation.define_method(:submit) do |*args, **options|
        attempts << id
        raise refusal
      end
      yield attempts
    ensure
      Conversation.define_method(:submit, original)
    end

    def stub_acceptance
      stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    end
end
