require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The phone app's Settings tab (docs/native-app.md, "Settings"): one row per
# place, each its own web page. Before, three rows opened You, /settings drew a
# hidden copy of it with the notification bridge on it, the Watches showed only
# once one had a token, and "on this iPhone" counted any of the person's phones.
# A build reading ios_v3 starts the tab at /settings itself, so the page draws
# every row the app's own screen had: the places with Notifications' and the
# Watch's status, Version, and Sign out.
class PhoneSettingsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  APP = { "User-Agent" => "APNs/sandbox; Hotwire Native iOS; Turbo Native iOS; bridge-components: [notification-token]" }.freeze
  # As WKWebView sends it from a build reading ios_v3 (AppDelegate): its version, and the session component.
  APP_V3 = { "User-Agent" => "NativeSignIn/1; APNs/sandbox; Lanyard/0.1(12); Hotwire Native iOS; Turbo Native iOS; " \
    "bridge-components: [alert notification-token session]" }.freeze
  TOKEN = "a1" * 32

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
  end
  teardown { remove_sidecar_settings }

  test "/settings is the list alone, with no hidden copy of You" do
    get settings_path, headers: APP
    assert_response :success
    assert_select "#native_notifications", count: 0
    assert_select "#user_name", count: 0
    assert_select ".settings-nav__link[href=?]", settings_notifications_path, text: /\ANotifications/
    assert_select ".settings-nav__link[href=?]", settings_watches_path, text: /\AApple Watch/
  end

  test "in the app, /settings is the whole Settings tab: every place, Notifications and the Watch with their status, Version and Sign out" do
    get settings_path, headers: APP_V3
    assert_response :success
    assert_select ".settings-nav__link[href=?]", settings_account_path, text: /You/
    assert_select ".settings-nav__link[href=?]", settings_notifications_path do
      assert_select ".settings-nav__label", "Notifications"
      assert_select ".settings-nav__value", "Not available"
    end
    assert_select ".settings-nav__link[href=?]", settings_watches_path do
      assert_select ".settings-nav__label", "Apple Watch"
      assert_select ".settings-nav__value", "Not signed in"
    end
    %w[ subscriptions_path settings_invitations_path workspaces_path ].each do |place|
      assert_select ".settings-nav__link[href=?]", public_send(place), 1, place
    end
    workspace = @user.workspaces.sole
    %w[ workspace_connectors_path workspace_helpers_path ].each do |place|
      assert_select ".settings-nav__link[href=?]", public_send(place, workspace), 1, place
    end
    assert_select ".settings-nav__link[href=?]", workspace_usage_path(workspace), text: /Usage/
    assert_select ".settings-nav__link[href=?]", agent_path(@agent), text: /#{@agent.name}/

    assert_select "#settings_about" do
      assert_select ".settings-nav__label", "Version"
      assert_select ".settings-nav__value", "0.1 (12)"
    end
    assert_select "#settings_about_help", "Connected to www.example.com."
    assert_select "#settings_sign_out form[action=?][data-controller~='native--session']", sign_out_path(phone: "forget") do
      assert_select "input[name=_method][value=delete]"
      assert_select "button[data-turbo-confirm*='signs out your Watch']", "Sign out"
    end
    assert_select "#settings_sign_out_help", /Also signs out the Watch and stops this iPhone's notifications/

    @user.watches.create!(name: "Robin's Watch")
    get settings_path, headers: APP_V3
    assert_select ".settings-nav__link[href=?] .settings-nav__value", settings_watches_path, "Signed in",
      "a Watch holding a token is signed in, whether or not it is still paired"
  end

  test "a browser's /settings has no Version, no second Sign out, and no status beside a place" do
    get settings_path
    assert_select "#settings_about", count: 0
    assert_select "#settings_sign_out", count: 0
    assert_select ".settings-nav__value", count: 0
  end

  # The app's own screen opened iOS's Settings for a refusal: the one place that can allow notifications again.
  test "in the app, Notifications iOS refused says Off and opens the iPhone's Settings for the app" do
    with_apns do
      post push_attempts_path, params: { outcome: "refused", code: 1 }, headers: APP_V3, as: :json
      get settings_path, headers: APP_V3
      assert_select ".settings-nav__link[href='app-settings:']" do
        assert_select ".settings-nav__label", "Notifications"
        assert_select ".settings-nav__value", "Off"
      end

      post push_devices_path, params: { token: TOKEN }, headers: APP_V3, as: :json
      get settings_path, headers: APP_V3
      assert_select ".settings-nav__link[href=?] .settings-nav__value", settings_notifications_path, "On"
    end
  end

  # The app's own screen asked afresh each time it showed. The page follows broadcasts instead: closing
  # Notifications' sheet after a refusal, the row beneath already says Off.
  test "in the app, the Settings page hears its status change: a token posted or refused, a Watch connected or revoked" do
    get settings_path, headers: APP_V3
    assert_select "turbo-cable-stream-source[signed-stream-name=?]", Turbo::StreamsChannel.signed_stream_name([ @user, :settings ])
    get settings_path
    assert_select "turbo-cable-stream-source[signed-stream-name=?]", Turbo::StreamsChannel.signed_stream_name([ @user, :settings ]), count: 0

    with_apns do
      settings_told { post push_attempts_path, params: { outcome: "refused", code: 1 }, headers: APP_V3, as: :json }
      settings_told { post push_devices_path, params: { token: TOKEN }, headers: APP_V3, as: :json }
      watch = settings_told { @user.watches.create!(name: "Robin's Watch") }
      settings_told(told: false) { watch.used! }
      settings_told { watch.revoke! }
    end
  end

  test "Sign out from the app's Settings page ends the session, revokes the Watch and forgets this phone's token alone" do
    with_apns do
      post push_devices_path, params: { token: TOKEN }, headers: APP_V3, as: :json
      other = @user.push_devices.create!(token: "b2" * 32, environment: "sandbox") # another phone, signed in elsewhere
      watch = @user.watches.create!(name: "Robin's Watch")

      delete sign_out_path(phone: "forget"), headers: APP_V3
      assert_redirected_to turbo_resume_historical_location_url, "the app's session component starts its tabs afresh"
      assert_not @user.push_devices.exists?(token: TOKEN)
      assert @user.push_devices.exists?(other.id)
      assert watch.reload.revoked_at

      get settings_path, headers: APP_V3
      assert_response :unauthorized
    end
  end

  test "You is the name and email alone" do
    get settings_account_path, headers: APP
    assert_select "#user_name"
    assert_select "#native_notifications", count: 0
    assert_select "#watches", count: 0
  end

  test "Apple Watch is a page of its own, which says so when none is connected and lists one that is" do
    get settings_watches_path, headers: APP
    assert_response :success
    assert_select "title", text: "Apple Watch"
    assert_select "#watches_title", "Apple Watch"
    assert_select "#watches", text: /No Apple Watch is connected/
    assert_select "#watches_help", text: /open this app on the iPhone it is paired with/

    watch = @user.watches.create!(name: "Robin's Watch")
    get settings_watches_path, headers: APP
    assert_select "#watches form[action=?] button", watch_path(watch), text: "Revoke"
    delete watch_path(watch)
    assert_redirected_to settings_watches_path
  end

  test "Notifications is a page of its own, and on this iPhone means this phone, not another of the person's" do
    with_apns do
      @user.push_devices.create!(token: "b2" * 32, environment: "sandbox") # another phone, signed in elsewhere
      get settings_notifications_path, headers: APP
      assert_response :success
      assert_select "title", text: "Notifications"
      assert_select "#native_notifications button", text: "Turn on"
      assert_select "#push_messages[disabled]"

      post push_devices_path, params: { token: TOKEN }, headers: APP, as: :json
      assert_response :created
      get settings_notifications_path, headers: APP
      assert_select "#native_notifications .ui-row__note", text: "On"
      assert_select "#native_notifications button", count: 0
      assert_select "#push_messages:not([disabled])"
      assert_not_includes response.body, TOKEN, "the page never shows the token"

      patch settings_notifications_path, params: { user: { push_errors: "0" } }
      assert_redirected_to settings_notifications_path

      get settings_notifications_path
      assert_select "#native_notifications", count: 0, msg: "a browser has its own"
      assert_select "#notifications_title", "Notifications"
    end
  end

  test "the app's Settings tab is drawn from /settings.json: each place once, Models and Invitations for an admin only" do
    get settings_path(format: :json)
    assert_response :success
    sections = response.parsed_body.fetch("sections")
    assert_equal [ "Profile", nil, nil, "Agents" ], sections.pluck("title")
    places = sections.flat_map { it["places"] }
    assert_equal [ "account", "notifications", "watch", "models", "invitations", "workspaces", "connectors", "helpers", "usage", "agent" ], places.pluck("id")
    assert_equal places.pluck("path").uniq, places.pluck("path"), "no two rows open the same page"
    assert_equal [ "You", "/settings/account" ], places.first.values_at("name", "path")
    assert_equal [ @agent.name, agent_path(@agent) ], places.last.values_at("name", "path")

    with_setting(:access, :admins, []) { get settings_path(format: :json) }
    ids = response.parsed_body["sections"].flat_map { it["places"] }.pluck("id")
    assert_not_includes ids, "models"
    assert_not_includes ids, "invitations"
  end

  # Before, the row said nothing once it was drawn from /settings.json; before
  # that, it said iOS's permission alone.
  test "/settings.json says whether notifications are on for this phone, as its page does" do
    get settings_path(format: :json), headers: APP
    assert_equal "Not available", notifications_status, "no APNs key, as the page says"
    assert_nil response.parsed_body["sections"].flat_map { it["places"] }.find { it["id"] == "watch" }["value"], "the app says the Watch's own"

    with_apns do
      @user.push_devices.create!(token: "b2" * 32, environment: "sandbox") # another phone, signed in elsewhere
      get settings_path(format: :json), headers: APP
      assert_equal "Not set up", notifications_status

      post push_attempts_path, params: { outcome: "refused", code: 1 }, headers: APP, as: :json
      assert_response :created
      get settings_path(format: :json), headers: APP
      assert_equal "Off", notifications_status

      post push_devices_path, params: { token: TOKEN }, headers: APP, as: :json
      assert_response :created
      get settings_path(format: :json), headers: APP
      assert_equal "On", notifications_status
    end
  end

  private
    # Turbo waits half a second, on another thread, before a refresh goes: here it goes at once.
    class AtOnce
      def initialize(**) = nil
      def debounce = yield
      def wait = nil
    end

    # What the block returns, once the Settings page has been told to refresh, or not.
    def settings_told(told: true)
      result = nil
      waits, Turbo::ThreadDebouncer.debouncer_class = Turbo::ThreadDebouncer.debouncer_class, AtOnce
      streams = capture_turbo_stream_broadcasts([ @user, :settings ]) { perform_enqueued_jobs { result = yield } }
      assert_equal told, streams.any? { it["action"] == "refresh" }
      result
    ensure
      Turbo::ThreadDebouncer.debouncer_class = waits
    end

    def notifications_status
      assert_response :success
      response.parsed_body["sections"].flat_map { it["places"] }.find { it["id"] == "notifications" }.fetch("value")
    end

    def with_apns(&block)
      { key_id: "KEY1234567", team_id: "TEAM123456", private_key: "made-up", topic: "org.example.app" }
        .reduce(block) { |inner, (key, value)| -> { with_setting(:apns, key, value, &inner) } }.call
    end
end
