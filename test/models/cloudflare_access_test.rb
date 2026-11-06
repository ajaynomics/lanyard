require "test_helper"

class CloudflareAccessTest < ActionDispatch::IntegrationTest
  CERTS = "https://avery-test.cloudflareaccess.com/cdn-cgi/access/certs"

  setup do
    @key = OpenSSL::PKey::RSA.generate(2048)
    @jwk = JSON::JWK.new(@key.public_key, kid: "access-key-1")
    stub_request(:get, CERTS).to_return(body: { keys: [ @jwk ] }.to_json)
  end

  def assertion(claims = {}, key: @key, kid: "access-key-1")
    now = Time.current.to_i
    jwt = JSON::JWT.new({ iss: "https://avery-test.cloudflareaccess.com", aud: [ "test-audience-tag" ], sub: "access-user-1",
      email: "Operator@example.com", iat: now, nbf: now, exp: now + 600 }.merge(claims))
    jwt.kid = kid
    jwt.sign(key, :RS256).to_s
  end

  test "an admitted person behind Access is signed in by the signed assertion alone, once" do
    get root_path, headers: { CloudflareAccess::HEADER => assertion }
    user = User.find_by!(email: "operator@example.com")
    assert_redirected_to bot_conversations_path(user.bots.first)
    assert_equal "cloudflare-access:access-user-1", user.oidc_sub
    assert_equal 1, user.bots.count

    follow_redirect!
    assert_response :success, "the session carries on without the header"
    assert_equal 1, User.count
  end

  test "a forged, foreign, expired or unsigned assertion, or the bare email header, signs nobody in" do
    other = OpenSSL::PKey::RSA.generate(2048)
    refused = {
      "another key" => assertion(key: other),
      "another audience" => assertion({ aud: [ "someone-else" ] }),
      "another issuer" => assertion({ iss: "https://evil.cloudflareaccess.com" }),
      "expired" => assertion({ exp: 1.minute.ago.to_i }),
      "not admitted" => assertion({ email: "stranger@example.com" }),
      "unsigned" => JSON::JWT.new(iss: "https://avery-test.cloudflareaccess.com", aud: [ "test-audience-tag" ], email: "operator@example.com", exp: 1.hour.from_now.to_i).to_s
    }
    refused.each do |what, token|
      get root_path, headers: { CloudflareAccess::HEADER => token }
      assert_redirected_to sign_in_path, what
    end
    get root_path, headers: { "Cf-Access-Authenticated-User-Email" => "operator@example.com" }
    assert_redirected_to sign_in_path
    assert_equal 0, User.count
  end
end
