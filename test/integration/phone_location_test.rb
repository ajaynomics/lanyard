require "test_helper"
require "yaml"
require_relative "../test_helpers/agent_test_helper"

class PhoneLocationTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  VERIFIER = "proof-only-verifier-abcdefghijklmnopqrstuvwxyz".freeze
  PHONE = { "User-Agent" => "NativeSignIn/1; Hotwire Native iOS; bridge-components: [phone-location]" }.freeze
  PURPOSE = "Ajent uses your location when you ask your agent where you are, or for things nearby.".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the person the test signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
    @cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @cache
    remove_sidecar_settings
  end

  test "an opted-in tool waits for a tap, then keeps the single fix on its own call" do
    travel_to Time.utc(2026, 11, 22, 12)
    call = ask_location
    assert_predicate call, :awaiting_person?
    assert_equal :location, call.asks
    assert_nil call.result
    phone = sign_in_phone
    other_phone = sign_in_phone
    route = location_path(call)

    phone.get conversation_path(@conversation), headers: PHONE
    phone.assert_select 'meta[name="native-phone-session"][content="true"]'
    phone.assert_select "button", "Share location once"
    phone.post route, as: :json
    phone.assert_response :no_content
    phone.post route, as: :json
    phone.assert_response :conflict
    other_phone.post route, as: :json
    other_phone.assert_response :conflict
    other_phone.patch route, params: share, as: :json
    other_phone.assert_response :conflict
    assert_nil call.reload.result

    another_conversation = create_conversation(@agent, durable_id: "other")
    phone.patch location_path(call, conversation: another_conversation), params: share, as: :json
    phone.assert_response :not_found
    assert_nil call.reload.result
    other_call = ask_location(call_id: "toolu_other", entry_id: 2)
    phone.patch location_path(other_call), params: share, as: :json
    phone.assert_response :conflict
    assert_nil other_call.reload.result

    log = capture_location_log do
      with_forgery_protection do
        phone.patch route, params: share, headers: { "HTTPS" => "on", "Sec-Fetch-Site" => "same-origin" }, as: :json
      end
    end
    assert_includes log, '["result", "[FILTERED]"]'
    assert_not_includes log, "49.25"
    assert_not_includes log, "-123.12"
    phone.assert_response :no_content
    assert_predicate call.reload, :succeeded?
    assert_equal share.fetch(:location_fix).stringify_keys.merge("status" => "shared"), call.result
    assert_nil call.answer
    phone.patch route, params: { outcome: "denied" }, as: :json
    phone.assert_response :conflict
    assert_equal "shared", call.reload.result["status"]

    phone.get conversation_path(@conversation), headers: PHONE
    phone.assert_select "##{call.dom_target}", text: /Location shared/
    assert_not_includes phone.response.body, "49.25"
  end

  test "only the phone that started a fix can report iOS denial" do
    call = ask_location
    route = location_path(call)
    phone = sign_in_phone
    phone.patch route, params: { outcome: "denied" }, as: :json
    phone.assert_response :conflict
    phone.post route, as: :json
    phone.assert_response :no_content
    phone.patch route, params: { outcome: "denied" }, as: :json
    phone.assert_response :no_content
    assert_equal({ "status" => "denied", "message" => "The iPhone didn't allow location access." }, call.reload.result)
    assert_nil call.answer
    phone.get conversation_path(@conversation), headers: PHONE
    phone.assert_select "##{call.dom_target}", text: /The iPhone didn't allow location access\./
  end

  test "a signed-in phone in another workspace cannot claim, answer, or close the request" do
    call = ask_location
    route = location_path(call)
    outsider = User.sign_in!(sub: "other-location-owner", email: "outsider@example.com", name: "Other owner")
    with_setting(:access, :emails, [ @user.email, outsider.email ]) do
      phone = sign_in_phone(user: outsider)
      phone.post route, as: :json
      phone.assert_response :not_found
      phone.patch route, params: share, as: :json
      phone.assert_response :not_found
      phone.delete route, params: { outcome: "declined" }, as: :json
      phone.assert_response :not_found
    end
    assert_predicate call.reload, :awaiting_person?
    assert_nil call.location_session_digest
    assert_nil call.result
  end

  {
    "restricted" => "This iPhone restricts location access.",
    "services_off" => "Location Services is off on this iPhone."
  }.each do |outcome, explanation|
    test "the phone can report #{outcome.tr('_', ' ')} without sending a fix" do
      call = ask_location
      route = location_path(call)
      phone = sign_in_phone
      phone.post route, as: :json
      phone.assert_response :no_content
      phone.patch route, params: { outcome: outcome }, as: :json
      phone.assert_response :no_content
      assert_equal({ "status" => outcome, "message" => explanation }, call.reload.result)

      phone.get conversation_path(@conversation), headers: PHONE
      phone.assert_select "##{call.dom_target}", text: /#{Regexp.escape(explanation)}/
    end
  end

  test "a native-looking browser cannot start a fix and can say there's no phone" do
    call = ask_location
    route = location_path(call)
    get conversation_path(@conversation), headers: PHONE
    assert_select 'meta[name="native-phone-session"]', count: 0
    assert_select "button:not([hidden])", text: "Share location once", count: 0
    assert_select "button", "I don't have an iPhone"
    post route, headers: PHONE, as: :json
    assert_response :forbidden
    patch route, headers: PHONE, params: share, as: :json
    assert_response :forbidden
    assert_nil call.reload.result

    delete route, params: { outcome: "no_phone" }
    assert_redirected_to @conversation
    assert_equal({ "status" => "no_phone", "message" => "No signed-in iPhone was available to share a location." }, call.reload.result)
  end

  test "a malformed or expired fix never becomes a result" do
    call = ask_location
    route = location_path(call)
    phone = sign_in_phone
    phone.post route, as: :json
    phone.assert_response :no_content
    phone.patch route, params: share.tap { it[:location_fix][:latitude] = 91 }, as: :json
    phone.assert_response :unprocessable_entity
    assert_nil call.reload.result
    travel 6.minutes
    phone.patch route, params: share, as: :json
    phone.assert_response :conflict
    assert_nil call.reload.result
  end

  test "the phone alone declares the exact when-in-use purpose without background location" do
    spec = YAML.safe_load_file(Rails.root.join("ios/project.yml"))
    phone = spec.dig("targets", "LanyardPhone", "info", "properties")
    watch = spec.dig("targets", "LanyardWatch", "info", "properties")
    assert_equal PURPOSE, phone["NSLocationWhenInUseUsageDescription"]
    assert_equal [ "NSLocationWhenInUseUsageDescription" ], phone.keys.grep(/^NSLocation/)
    assert_empty watch.keys.grep(/^NSLocation/)
    assert_not_includes phone.fetch("UIBackgroundModes"), "location"
  end

  private
    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    def capture_location_log
      output = StringIO.new
      old_record, old_controller = ActiveRecord::Base.logger, ActionController::Base.logger
      ActiveRecord::Base.logger = ActionController::Base.logger = ActiveSupport::Logger.new(output).tap { it.level = :debug }
      yield
      output.string
    ensure
      ActiveRecord::Base.logger, ActionController::Base.logger = old_record, old_controller
    end

    def ask_location(call_id: "toolu_location", entry_id: 1)
      @agent.update!(tool_names: @agent.tool_names | [ "request_phone_location" ])
      attributes = { task_id: 7, call_id: call_id, tool: "request_phone_location", arguments: {} }
      digest = Invocation.digest_for(@conversation, **attributes)
      @conversation.messages.create!(entry_key: "location-tool-#{entry_id}", entry_id: entry_id, role: "assistant", content: "",
        tool_calls: [ { "id" => call_id, "name" => attributes[:tool] } ])
      Invocation.receive(@conversation.reload, **attributes, digest: digest)
      @conversation.invocations.find_by!(call_id: attributes.fetch(:call_id))
    end

    def sign_in_phone(user: @user)
      url = NativeSignIn.return_url(user, email: user.email, challenge: NativeSignIn.challenge_of(VERIFIER))
      code = CGI.parse(URI.parse(url).query).fetch("code").sole
      open_session.tap do |app|
        app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
        app.assert_redirected_to root_path
      end
    end

    def location_path(call, conversation: @conversation) = conversation_invocation_location_request_path(conversation, call, format: :json)
    def share = { outcome: "shared", location_fix: { latitude: 49.25, longitude: -123.12, accuracy_m: 16.5, timestamp: Time.current.utc.iso8601 } }
end
