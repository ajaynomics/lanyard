require "test_helper"
require_relative "../test_helpers/fake_ajent"

# The phone app's sign-in (NativeSignIn), through the real OmniAuth strategy
# against a fake Ajent. The integration session here is the app's browser
# sheet; `open_session` is the app's own web view, a separate cookie jar, as on
# the phone.
class PhoneAppSignInTest < ActionDispatch::IntegrationTest
  include FakeAjentTestHelper

  VERIFIER = "a-verifier-only-the-app-knows-0123456789-abcdefghijklmnop".freeze
  APP_UA = "Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 NativeSignIn/1; Hotwire Native iOS; Turbo Native iOS;".freeze

  setup do
    @test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = false
    @ajent = FakeAjent.new
    # The test environment's cache keeps nothing; a code's single use needs one that does.
    @cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    OmniAuth.config.test_mode = @test_mode
    Rails.cache = @cache
  end

  test "the sheet signs in at the provider and hands the app a code, and the app's web view gets the session" do
    app = open_session
    app.get root_path
    app.assert_redirected_to sign_in_path

    code = sign_in_in_the_sheet
    get root_path
    assert_redirected_to sign_in_path, "the sheet itself is not signed in"

    app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
    app.assert_redirected_to root_path, "back to the page the app was sent to sign in from"
    app.follow_redirect!
    app.assert_response :success
    app.assert_select "h1", "Agents"
    assert_equal User.find_by!(oidc_sub: "ajent-maya").id, app.session[:user_id] # tenancy-ok: test reads the person it signed in
    assert_equal "operator@example.com", app.session[:email]
    cookie = Array(app.response.headers["Set-Cookie"]).flat_map(&:lines).grep(/_durable_assistants_session/).first.to_s.downcase
    assert_includes cookie, "httponly"
    assert_includes cookie, "samesite=lax"
  end

  test "the session it starts asks for a Watch's token, and signs out, as any other" do
    app = open_session
    app.post native_sign_in_path, params: { code: sign_in_in_the_sheet, code_verifier: VERIFIER }
    app.assert_redirected_to root_path

    with_forgery_protection do
      # As TokenMint asks (ios/Phone/TokenMint.swift).
      app.post watches_path(format: :json), params: { name: "Robin's Watch" }, as: :json,
        headers: { "Sec-Fetch-Site" => "same-origin", "HTTPS" => "on" }
    end
    app.assert_response :created
    assert app.response.parsed_body["token"].present?

    app.delete sign_out_path
    app.get root_path
    app.assert_redirected_to sign_in_path
  end

  test "a code is good once" do
    code = sign_in_in_the_sheet
    first, second = open_session, open_session
    first.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
    first.assert_redirected_to root_path

    second.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
    second.assert_response :unprocessable_entity
    second.assert_select "h1", "Sign-in did not complete"
    assert_nil second.session[:user_id]
  end

  test "the wrong verifier signs nobody in, and spends the code" do
    code = sign_in_in_the_sheet
    app = open_session
    app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER.reverse }
    app.assert_response :unprocessable_entity
    assert_nil app.session[:user_id]

    app.post native_sign_in_path, params: { code: code }
    app.assert_response :unprocessable_entity

    app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
    app.assert_response :unprocessable_entity, "a code tried with a wrong verifier is gone"
    assert_nil app.session[:user_id]
  end

  test "a code is good for two minutes" do
    code = sign_in_in_the_sheet
    travel NativeSignIn::EXPIRES_IN + 1.second

    app = open_session
    app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
    app.assert_response :unprocessable_entity
    assert_nil app.session[:user_id]
  end

  test "a forged or altered code signs nobody in" do
    code = sign_in_in_the_sheet
    app = open_session
    [ nil, "", "forged", code.sub(/\A./) { it == "A" ? "B" : "A" } ].each do |forged|
      app.post native_sign_in_path, params: { code: forged, code_verifier: VERIFIER }
      app.assert_response :unprocessable_entity, forged.inspect
    end
    assert_nil app.session[:user_id]
  end

  test "someone taken off the list after signing in in the sheet is not let in" do
    code = sign_in_in_the_sheet
    app = open_session
    with_setting(:access, :emails, []) do
      app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }
    end
    app.assert_response :unprocessable_entity
    assert_nil app.session[:user_id]
  end

  test "someone not admitted gets no code, and no session" do
    get new_native_sign_in_path(code_challenge: challenge, code_challenge_method: "S256")
    sign_in_through FakeAjent.new(email: "stranger@example.com")

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_select ".flash", /not set up/
    assert_nil session[:native_sign_in]
    assert_equal 0, User.count # tenancy-ok: proving nobody was created
  end

  test "without a well-formed S256 challenge the sheet is refused and nothing is kept" do
    [ {}, { code_challenge: challenge }, { code_challenge: challenge, code_challenge_method: "plain" },
      { code_challenge: "short", code_challenge_method: "S256" } ].each do |params|
      get new_native_sign_in_path(params)
      assert_response :unprocessable_entity, params.inspect
      assert_nil session[:native_sign_in]
    end
  end

  test "with no challenge in the browser's session, the callback signs that browser in as before" do
    sign_in_through @ajent
    assert_redirected_to root_path
    assert session[:user_id]
  end

  test "a sign-in begun for the app and left goes back to normal: after ten minutes, or from the web sign-in page" do
    get new_native_sign_in_path(code_challenge: challenge, code_challenge_method: "S256")
    travel NativeSignInsController::PENDING_FOR + 1.second
    sign_in_through @ajent
    assert_redirected_to root_path
    delete sign_out_path

    get new_native_sign_in_path(code_challenge: challenge, code_challenge_method: "S256")
    get sign_in_path
    sign_in_through @ajent
    assert_redirected_to root_path
  end

  test "the sheet's page goes straight on to the provider, as the sign-in button would" do
    with_forgery_protection { get new_native_sign_in_path(code_challenge: challenge, code_challenge_method: "S256") }
    assert_response :success
    assert_select "form[action=?][method=post][data-controller=auto-submit]", ajent_auth_path do
      assert_select "button", "Continue with Ajent"
    end
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "starting a sign-in still needs a request from the page itself" do
    stub_request(:any, FakeAjent::URLS).to_rack(@ajent)
    get new_native_sign_in_path(code_challenge: challenge, code_challenge_method: "S256")
    with_forgery_protection do
      post ajent_auth_path, headers: { "HTTPS" => "on", "Sec-Fetch-Site" => "cross-site" }
      assert_redirected_to %r{/auth/failure\?message=}
      assert_not_requested :get, %r{/oidc/authorize}

      post ajent_auth_path, headers: { "HTTPS" => "on" }
      assert_redirected_to %r{/auth/failure\?message=}, "over https, a request that says nothing of where it came from is refused too"

      post ajent_auth_path, headers: { "HTTPS" => "on", "Sec-Fetch-Site" => "same-origin" }
      assert_redirected_to %r{\Ahttps?://www\.example\.com/oidc/authorize\?}
    end
  end

  test "another site cannot post a code, whatever it holds" do
    code = sign_in_in_the_sheet
    app = open_session
    %w[ cross-site same-site ].each do |site|
      app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }, headers: { "Sec-Fetch-Site" => site }
      app.assert_response :forbidden
    end
    # The app's own post, as WebKit labels a load it did not get from a page.
    app.post native_sign_in_path, params: { code: code, code_verifier: VERIFIER }, headers: { "Sec-Fetch-Site" => "none" }
    app.assert_redirected_to root_path
  end

  test "the sign-in page offers the phone app its sheet, and everyone else the button" do
    get sign_in_path, headers: { "User-Agent" => APP_UA }
    assert_select "a[href=?]", new_native_sign_in_path, text: "Sign in with Ajent"
    assert_select "form[action=?]", ajent_auth_path, false

    get sign_in_path, headers: { "User-Agent" => "Mozilla/5.0 (iPhone) Hotwire Native iOS; Turbo Native iOS;" }
    assert_select "button", "Sign in with Ajent"
    assert_select "a[href=?]", new_native_sign_in_path, false

    with_setting(:oidc, :client_id, nil) do
      get sign_in_path, headers: { "User-Agent" => APP_UA }
      assert_select "a[href=?]", new_native_sign_in_path, false
      assert_select "p", /not set up here/
    end
  end

  private
    def challenge = NativeSignIn.challenge_of(VERIFIER)

    # The sheet: the app's start address, then the provider, then back with a code.
    def sign_in_in_the_sheet
      get new_native_sign_in_path(code_challenge: challenge, code_challenge_method: "S256")
      assert_response :success
      sign_in_through @ajent
      assert_redirected_to %r{\Aorg\.durableassistants\.companion://signed-in\?code=[^&]+\z}
      assert_nil session[:user_id]
      assert_nil session[:native_sign_in]
      Rack::Utils.parse_query(URI(response.location).query).fetch("code")
    end

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
