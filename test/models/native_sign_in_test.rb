require "test_helper"

class NativeSignInTest < ActiveSupport::TestCase
  VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".freeze

  setup do
    @cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @user = User.sign_in!(sub: "ajent-maya", email: "operator@example.com", name: "Maya")
  end
  teardown { Rails.cache = @cache }

  test "the challenge is RFC 7636's S256 of the verifier" do
    # RFC 7636, appendix B.
    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", NativeSignIn.challenge_of(VERIFIER)
    assert NativeSignIn.challenge?("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    [ nil, "", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-c", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw+cM", [ "x" ] ].each do
      assert_not NativeSignIn.challenge?(it), it.inspect
    end
  end

  test "a code names the person and the email they signed in with, once, for the verifier's holder" do
    code = code_for(VERIFIER)
    assert_not_includes code, "operator", "the code says nothing to whoever sees it"

    sign_in = NativeSignIn.redeem(code, verifier: VERIFIER)
    assert_equal @user, sign_in.user
    assert_equal "operator@example.com", sign_in.email
    assert_nil NativeSignIn.redeem(code, verifier: VERIFIER), "used"
  end

  test "a code with the wrong verifier, or none, or after two minutes, is nobody" do
    assert_nil NativeSignIn.redeem(code_for(VERIFIER), verifier: VERIFIER.reverse)
    assert_nil NativeSignIn.redeem(code_for(VERIFIER), verifier: nil)
    assert_nil NativeSignIn.redeem(code_for(VERIFIER), verifier: "short")

    code = code_for(VERIFIER)
    travel NativeSignIn::EXPIRES_IN + 1.second
    assert_nil NativeSignIn.redeem(code, verifier: VERIFIER)
  end

  test "a forged code is nobody, and so is the code of someone since deleted" do
    [ nil, "", "garbage", 42 ].each { assert_nil NativeSignIn.redeem(it, verifier: VERIFIER) }

    code = code_for(VERIFIER)
    @user.destroy!
    assert_nil NativeSignIn.redeem(code, verifier: VERIFIER)
  end

  test "the app's scheme comes from settings, and a web scheme or a typo fails the boot" do
    assert_equal "org.durableassistants.companion", NativeSignIn.scheme
    with_setting(:app, :native_sign_in_scheme, "org.example.lanyard") do
      assert_equal "org.example.lanyard", NativeSignIn.scheme
      assert_match %r{\Aorg\.example\.lanyard://signed-in\?code=}, NativeSignIn.return_url(@user, email: "operator@example.com", challenge: "x")
    end
    [ "https", "javascript", "Org.Example", "two words", "1app" ].each do |scheme|
      with_setting(:app, :native_sign_in_scheme, scheme) do
        error = assert_raises(ArgumentError) { NativeSignIn.scheme }
        assert_match "APP__NATIVE_SIGN_IN_SCHEME", error.message
      end
    end
  end

  private
    def code_for(verifier)
      url = NativeSignIn.return_url(@user, email: "operator@example.com", challenge: NativeSignIn.challenge_of(verifier))
      Rack::Utils.parse_query(URI(url).query).fetch("code")
    end
end
