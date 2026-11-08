require "test_helper"
require_relative "../test_helpers/concourse_test_helper"

# The join contract agreed with Concourse, in this app's one file that speaks
# it, against the stand-in (FakeConcourse): the code's redemption, where an
# agent stands, and retiring it.
class ConcourseConnectTest < ActiveSupport::TestCase
  include ConcourseTestHelper

  REDIRECT = "http://localhost/concourse/callback"
  VERIFIER = "a-verifier-of-at-least-forty-three-characters-for-pkce-s256"

  setup { @concourse = stub_fake_concourse }

  test "a code redeems once, for the agent waiting for approval and its machine client" do
    code = approve

    grant = redeem(code)

    assert_equal({ "address" => "#{ORIGIN}/a2a/acme/acme/iris", "organization" => "acme", "handle" => "iris", "status" => "awaiting_approval" }, grant["agent"])
    assert_equal "acme/iris", grant["path"], "kept as prefix/handle, which api/identity names"
    assert_equal [ "joined-2", "joined-secret-2", TOKEN_URL ], grant.values_at("client_id", "client_secret", "token_endpoint")
    error = assert_raises(DurableAssistants::Concourse::Client::Error) { redeem(code) }
    assert_equal [ 400, "invalid_grant" ], [ error.status, error.reason ]
    assert_equal "Concourse refused the join (invalid_grant). Start again.", error.message
  end

  test "an agent Concourse admits at once says so" do
    @concourse.admit_on_join = true
    assert_equal "admitted", redeem(approve).dig("agent", "status")
  end

  test "a code with the wrong verifier or redirect address is refused" do
    assert_raises(DurableAssistants::Concourse::Client::Error) { redeem(approve, verifier: VERIFIER.reverse) }
    error = assert_raises(DurableAssistants::Concourse::Client::Error) do
      DurableAssistants::Concourse::Connect.redeem(code: approve, redirect_uri: "http://localhost/elsewhere", code_verifier: VERIFIER)
    end
    assert_equal "invalid_grant", error.reason
  end

  test "a Concourse that names another token server than the install's is refused, the secret unsaid" do
    @concourse.token_endpoint = "https://elsewhere.example/oauth/token"

    error = assert_raises(DurableAssistants::Concourse::Client::Error) { redeem(approve) }

    assert_equal "Concourse named another token server than this install's, so #{ORIGIN}/a2a/acme/acme/iris was not saved. " \
      "An owner of its organization can retire it on Concourse's website.", error.message
    assert_no_match(/joined-secret/, error.message)
    assert_empty @concourse.revocations, "the secret goes nowhere, not even to retire it"
  end

  test "an address that isn't this Concourse's A2A URL for the organization and handle given is refused, and the agent retired" do
    {
      "another origin" => ->(agent, _) { "https://elsewhere.example/a2a/acme/acme/#{agent.handle}" },
      "a bare prefix/handle" => ->(agent, _) { "acme/#{agent.handle}" },
      "another organization" => ->(agent, base) { "#{base}/a2a/zeta/acme/#{agent.handle}" },
      "another handle" => ->(_, base) { "#{base}/a2a/acme/acme/someone" },
      "a longer path" => ->(agent, base) { "#{base}/a2a/acme/acme/#{agent.handle}/more" },
      "not a path at all" => ->(*) { "https://concourse.example:bad port" }
    }.each do |shape, address|
      @concourse.wire_address = address
      error = assert_raises(DurableAssistants::Concourse::Client::Error, shape) { redeem(approve) }
      assert_equal "Concourse answered the join in a shape this app does not understand, so nothing was kept.", error.message, shape
      assert_equal "retired", @concourse.agents.last.status, "#{shape}: the agent is not left with a secret nobody holds"
    end
  end

  test "Disconnect on an agent bound by hand before joining existed says only an owner can retire it, on the website" do
    client = client_for(redeem(approve))
    @concourse.revoke_status, @concourse.revoke_reason = 403, "not_a_connected_agent"
    error = assert_raises(DurableAssistants::Concourse::Client::Error) { client.revoke }
    assert_equal "acme/iris was connected by hand before joining existed, so only an owner of acme can retire it, on Concourse's website.", error.message
  end

  test "the handle offered keeps to Concourse's rule" do
    rule = /\A[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?\z/
    [ "Jordan Reyes", "--Iris--", "#{"Very long name " * 5}x", "Ölga's  ✨ agent", "✨" ].each do |name|
      assert_match rule, ConcourseAgent::Join.handle_for(Agent.new(name: name)), name
    end
    assert_equal "agent", ConcourseAgent::Join.handle_for(Agent.new(name: "✨"))
    assert_equal "very-long-name-very-long-name-very-long", ConcourseAgent::Join.handle_for(Agent.new(name: "Very long name " * 5))
  end

  test "where an agent stands: admitted, waiting, declined, or no longer accepted" do
    client = client_for(redeem(approve))
    assert_equal "awaiting_approval", client.standing

    @concourse.admit!
    assert_equal "admitted", client_for(@concourse.agents.last).standing

    @concourse.decline!
    assert_equal "declined", client_for(@concourse.agents.last).standing

    client_for(@concourse.agents.last).revoke
    assert_equal "disconnected", client_for(@concourse.agents.last).standing
  end

  test "a stale token is asked again before an agent is taken for retired" do
    @concourse.admit_on_join = true
    redeem(approve)
    stub_request(:post, TOKEN_URL).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { access_token: "stale", token_type: "Bearer", expires_in: 3600 }.to_json).then.to_rack(@concourse)

    assert_equal "admitted", client_for(@concourse.agents.last).standing
  end

  test "revoking is done on 204, and on the 401 a repeat gets; anything else keeps the agent" do
    agent = client_for(redeem(approve))
    agent.revoke
    assert_equal [ "acme/iris" ], @concourse.revocations

    client = DurableAssistants::Concourse::Client.new(organization: "acme", handle: "acme/assistant", client_id: "client-1", client_secret: "secret-1")
    stub_concourse_token
    stub_request(:post, "#{ORIGIN}/connect/revoke").with(headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" })
      .to_return(status: 401).then.to_return(status: 500).then.to_return(status: 204)
    assert_nothing_raised { client.revoke }
    error = assert_raises(DurableAssistants::Concourse::Client::Error) { client.revoke }
    assert_equal [ 500, "Concourse did not take acme/assistant off; it answered 500." ], [ error.status, error.message ]
    assert_nothing_raised { client.revoke }

    stub_request(:post, TOKEN_URL).to_return(status: 401, body: { error: "invalid_client" }.to_json)
    assert_nothing_raised { client.revoke }
  end

  private
    # The person approves on Concourse's page; the code it sends back.
    def approve(handle: "iris")
      url = DurableAssistants::Concourse::Connect.authorize_url(redirect_uri: REDIRECT, state: "s" * 22, handle: handle, name: "Iris",
        code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(VERIFIER), padding: false))
      URI.decode_www_form(URI(Net::HTTP.get_response(URI(url))["location"]).query).to_h.fetch("code")
    end

    def redeem(code, verifier: VERIFIER)
      DurableAssistants::Concourse::Connect.redeem(code: code, redirect_uri: REDIRECT, code_verifier: verifier)
    end

    def client_for(agent)
      agent = @concourse.agents.find { it.client_id == agent["client_id"] } if agent.is_a?(Hash)
      DurableAssistants::Concourse::Client.new(organization: agent.organization, handle: agent.address, client_id: agent.client_id, client_secret: agent.client_secret)
    end
end
