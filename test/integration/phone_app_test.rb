require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The web app as the phone app shows it (docs/native-app.md): pages without
# the web's header, titled for the app's own bar; a sign-in the app opens
# itself; Needs you, each card a sheet that closes and refreshes the list when
# answered; the app's own notifications, registered by device token; and its
# Sign out, which takes the Watch's token and the notifications with it.
class PhoneAppTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  APP = { "User-Agent" => "NativeSignIn/1; APNs/sandbox; Hotwire Native iOS; Turbo Native iOS; bridge-components: [alert button form haptic menu share toast approval tab-badge]" }.freeze
  TOKEN = "a1" * 32

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { status: "idle", entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "in the app a page has no header, back link or sign-out of the web's, and its title is its own name alone" do
    get settings_account_path, headers: APP
    assert_response :success
    assert_select "title", text: "You"
    assert_select ".app-header", count: 0
    assert_select ".settings__up", count: 0
    assert_select "meta[name=view-transition]", count: 0
    assert_select "script", text: /import "native"/
    assert_select "link[rel=stylesheet][href*='/native-']"
    assert_select "button", text: "Sign out", count: 0

    get settings_account_path
    assert_select "title", text: "You · Settings · #{DurableAssistants.config(:app, :name)}"
    assert_select ".app-header"
    assert_select "meta[name=view-transition]"
    assert_select "script", text: /import "native"/, count: 0
    assert_select "link[rel=stylesheet][href*='/native-']", count: 0
    assert_select "button", text: "Sign out"
  end

  # The app sets the badge on the tab the page names, among the tabs Rails serves: no tab is fixed in Swift.
  test "the badge names the tab it belongs on, one of the app's tabs" do
    get root_path, headers: APP
    tab = css_select("#app_badge").sole["data-native--tab-badge-tab-value"]
    assert_equal "needs-you", tab
    assert_includes PathConfiguration.fetch("ios_v3").dig(:settings, :tabs).pluck(:id), tab
  end

  test "a thread's actions are the app's menu, its title the bar's, and New agent the list's bar button" do
    get conversation_path(@conversation), headers: APP
    assert_select "title", text: @conversation.to_s
    assert_select "#chat_actions[data-controller~='bridge--menu']"
    assert_select "#chat_actions [data-bridge--menu-target=item][data-bridge-destructive=true]", text: "Archive agent"
    assert_select "#chat_actions [data-controller~='bridge--share'][data-bridge-url='#{conversation_url(@conversation)}']"

    get root_path, headers: APP
    assert_select "title", text: "Agents"
    assert_select "#app_badge[data-controller~='native--tab-badge']"
    assert_select "#new_agent[data-controller~='bridge--button'][data-bridge-ios-image]"

    get new_agent_path, headers: APP
    assert_select "form[data-controller~='bridge--form'] input[type=submit][data-bridge--form-target=submit]"
  end

  # Review, 2026-11-16: the New workspace sheet kept its own "Create Workspace" button, where every other form hands
  # its submit to the app's bar.
  test "the workspace forms hand their submit to the app's bar, in sentence case" do
    get new_workspace_path, headers: APP
    assert_select "form[data-controller~='bridge--form'] input[type=submit][data-bridge--form-target=submit][value=?]", "Create workspace"

    post workspaces_path, params: { workspace: { name: "Garden club" } }
    get edit_workspace_path(@user.workspaces.find_by!(name: "Garden club")), headers: APP
    assert_select "form[data-controller~='bridge--form'] input[type=submit][data-bridge--form-target=submit][value=?]", "Save"
  end

  test "signed in from the app's sheet, Rails tells the app to close it and refresh; a browser goes to its page" do
    delete sign_out_path
    mock_ajent_auth
    get "/auth/ajent/callback", headers: APP
    assert_redirected_to turbo_refresh_historical_location_url
    get root_path, headers: APP
    assert_response :success

    delete sign_out_path
    get conversation_path(@conversation)
    get "/auth/ajent/callback"
    assert_redirected_to conversation_path(@conversation)
  end

  test "signed out, the app is told so and opens its own sign-in; a browser is sent to the page" do
    delete sign_out_path
    get root_path, headers: APP
    assert_response :unauthorized
    get approvals_path, headers: APP
    assert_response :unauthorized
    get sign_in_path, headers: APP
    assert_response :success

    get root_path
    assert_redirected_to sign_in_path
  end

  test "Needs you lists every card waiting on the person, and each opens alone with Allow and Deny for the app's bar" do
    allow = waiting("forget_note", { "key" => "trip" })
    waiting("ask_person", { "question" => "Which day?", "options" => %w[ Monday Tuesday ] }, call_id: "toolu_q")
    mallory = create_user(name: "Mallory")
    waiting("forget_note", { "key" => "theirs" }, conversation: create_conversation(mallory.agents.sole, durable_id: "99"), call_id: "toolu_m")

    get approvals_path, headers: APP
    assert_response :success
    assert_select "title", text: "Needs you"
    assert_select "#approvals .conversation-row", count: 2
    assert_select "#approvals a[href=?]", approval_path(allow)

    get approval_path(allow), headers: APP
    assert_response :success
    assert_select "[data-controller~='native--approval'] button[data-native--approval-target=allow]", text: "Allow once"
    assert_select "[data-controller~='native--approval'] button[data-native--approval-target=deny]", text: "Deny"
    assert_select "form[data-controller~='bridge--haptic'] input[name=from][value=approvals]"
    # The app's code and styles come with it: the controller hands the pair to the app, the style hides the page's.
    assert_select "script[type=module]", text: /import "native"/
    assert_select "link[rel=stylesheet][href*='native']"
    assert_select "[data-controller~='native--approval'] button[data-native--approval-target]", count: 2

    # A browser loads none of it, so the page's own buttons answer.
    get approval_path(allow)
    assert_select "script[type=module]", text: /import "native"/, count: 0
  end

  test "answered from its sheet, a card closes it and refreshes Needs you beneath, which says so" do
    invocation = waiting("forget_note", { "key" => "trip" })
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(status: 200, body: { rung: true }.to_json)

    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny", from: "approvals" }, headers: APP
    assert_redirected_to turbo_refresh_historical_location_url
    assert invocation.reload.denied?
    # The web view's fetch follows the redirect before the app refreshes the list beneath.
    follow_redirect!(headers: APP.dup)
    get "/favicon.ico", headers: APP # as a browser fetches it on that page; an icon doesn't spend the message
    get "/refresh_historical_location", headers: APP
    get approvals_path, headers: APP
    assert_select ".flash[data-controller~='bridge--toast'][data-controller~='native--flash'][data-bridge-feedback=success]", text: /Denied\./

    other = waiting("forget_note", { "key" => "other" }, call_id: "toolu_2")
    post conversation_invocation_approval_path(@conversation, other), params: { decision: "deny", from: "approvals" }
    assert_redirected_to approvals_path
  end

  # Review, 2026-11-16: two cards from one agent read the same, "Allow forget note?". Each row now says which call,
  # by its first detail, as the Watch's list does (Invocation::Card).
  test "two cards with one title are told apart in Needs you by what each would do" do
    waiting("forget_note", { "key" => "trip" })
    waiting("forget_note", { "key" => "boat" }, call_id: "toolu_2")

    get approvals_path, headers: APP
    assert_select "#approvals .conversation-row__preview", text: "Allow forget note? · trip"
    assert_select "#approvals .conversation-row__preview", text: "Allow forget note? · boat"
  end

  test "an answer's message survives Hotwire Native's refresh hop, and shows once, on the list beneath" do
    invocation = waiting("forget_note", { "key" => "trip" })
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(status: 200, body: { rung: true }.to_json)

    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny", from: "approvals" }, headers: APP
    assert_redirected_to turbo_refresh_historical_location_url
    get turbo_refresh_historical_location_path, headers: APP
    assert_response :success
    assert_no_match "Denied.", response.body

    get approvals_path, headers: APP
    assert_select "#flash .flash[data-controller~='bridge--toast'][data-bridge-message=?]", "Denied."
    get approvals_path, headers: APP
    assert_select "#flash .flash", count: 0
  end

  test "the app registers its device token, with the build's push service; the phone's token follows whoever signs in" do
    post push_devices_path, params: { token: TOKEN.upcase }, headers: APP, as: :json
    assert_response :created
    device = @user.push_devices.sole
    assert_equal [ TOKEN, "sandbox" ], [ device.token, device.environment ]

    post push_devices_path, params: { token: "not a token" }, headers: APP, as: :json
    assert_response :unprocessable_entity

    mallory = create_user(name: "Mallory")
    mallory.push_devices.create!(token: "b2" * 32)
    post push_devices_path, params: { token: "b2" * 32 }, headers: APP, as: :json
    assert_empty mallory.push_devices.reload
    assert_equal 2, @user.push_devices.count
    # A phone's first token for a person is kept as registered; the same one again, at each launch, is not.
    post push_devices_path, params: { token: TOKEN }, headers: APP, as: :json
    assert_equal [ [ "registered", nil ] ] * 2, @user.push_attempts.pluck(:outcome, :code)
  end

  # Production, 2026-11-15: a phone with notifications allowed never registered, and Rails couldn't tell a tap that
  # never reached the app from iOS refusing. Each Turn on's outcome now reaches Rails, with iOS's or HTTP's code.
  test "the app and its page say what became of Turn on, and Rails keeps it with the app's version" do
    post push_attempts_path, params: { outcome: "failed", code: 3010 }, headers: { "User-Agent" => "Lanyard/0.1(12) APNs/production" }, as: :json
    assert_response :created
    post push_attempts_path, params: { outcome: "no_answer" }, headers: APP, as: :json
    assert_response :created
    post push_attempts_path, params: { outcome: "anything" }, headers: APP, as: :json
    assert_response :unprocessable_entity

    assert_equal [ [ "failed", 3010, "0.1(12)" ], [ "no_answer", nil, nil ] ], @user.push_attempts.order(:id).map { [ it.outcome, it.code, it.app_version ] }
  end

  # The app says iOS refused each time it comes to the front while notifications are off. Kept each time, it would
  # push the outcomes that say why out of the person's last few.
  test "a refusal the app repeats at each return to the front is kept once" do
    3.times { post push_attempts_path, params: { outcome: "refused", code: 1 }, headers: APP, as: :json }
    assert_response :ok, "nothing new to keep"
    post push_attempts_path, params: { outcome: "failed", code: 3010 }, headers: APP, as: :json
    post push_attempts_path, params: { outcome: "refused", code: 1 }, headers: APP, as: :json
    assert_equal [ [ "refused", 1 ], [ "failed", 3010 ], [ "refused", 1 ] ], @user.push_attempts.order(:id).pluck(:outcome, :code)
  end

  test "signed out, the app registers nothing" do
    delete sign_out_path
    post push_devices_path, params: { token: TOKEN }, headers: APP, as: :json
    assert_response :unauthorized
    post push_attempts_path, params: { outcome: "refused" }, headers: APP, as: :json
    assert_response :unauthorized
    assert_empty Push::Device.all # tenancy-ok: test checks nothing was stored for anyone
    assert_empty Push::Attempt.all # tenancy-ok: test checks nothing was stored for anyone
  end

  test "the app's Sign out revokes its Watch's token and forgets this phone's notifications" do
    watch = @user.watches.create!(name: "Robin's Watch")
    @user.push_devices.create!(token: TOKEN)
    @user.push_devices.create!(token: "c3" * 32)

    delete sign_out_path, params: { phone: "forget", device_token: TOKEN }, as: :json
    assert_response :no_content
    assert watch.reload.revoked_at
    assert_equal [ "c3" * 32 ], @user.push_devices.pluck(:token)
    get root_path, headers: APP
    assert_response :unauthorized
  end

  test "a browser's Sign out leaves the Watch alone, as before" do
    watch = @user.watches.create!(name: "Robin's Watch")
    delete sign_out_path
    assert_redirected_to sign_in_path
    assert_nil watch.reload.revoked_at
  end

  private
    def waiting(tool, arguments, conversation: @conversation, call_id: "toolu_#{tool}")
      digest = Invocation.digest_for(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments)
      Invocation.receive(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments, digest: digest)
      conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "#{tool} should wait for the person" }
    end
end
