require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# An X connector (McpServer::X): signed by hand with OAuth 1.0a, its reads run
# at once, and a post asks a person every time.
class McpServer::XTest < ActiveSupport::TestCase
  include AgentTestHelper

  API = McpServer::X::URL
  KEYS = { "consumer_key" => "ck-4417", "consumer_secret" => "cs-9902", "access_token" => "at-3318", "access_secret" => "as-6620" }.freeze

  setup do
    @agent = create_user.agents.sole
    @connector = @agent.user.mcp_servers.create!(name: "x", url: API, token: McpServer::X.token(KEYS))
    @connector.refresh
    stub_request(:get, "#{API}/users/me").to_return(json(data: { id: "42", username: "maya", name: "Maya" }))
  end

  # X's published example (docs.x.com, "Creating a signature" and
  # "Authorizing a request"): its made-up keys, nonce and time.
  EXAMPLE = {
    "consumer_key" => "xvz1evFS4wEEPTGEFPHBog", # gitleaks:allow
    "consumer_secret" => "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw", # gitleaks:allow
    "access_token" => "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb", # gitleaks:allow
    "access_secret" => "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE", # gitleaks:allow
    "nonce" => "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg" # gitleaks:allow
  }.freeze

  test "the signature and Authorization header match X's published example" do
    params = { "include_entities" => "true", "status" => "Hello Ladies + Gentlemen, a signed OAuth request!" }

    header = McpServer::X.authorization(:post, "https://api.x.com/1.1/statuses/update.json", EXAMPLE, params,
      nonce: EXAMPLE["nonce"], timestamp: 1318622958)

    expected = { "oauth_consumer_key" => EXAMPLE["consumer_key"], "oauth_nonce" => EXAMPLE["nonce"], "oauth_signature" => "Ls93hJiZbQ3akF3HF3x1Bz8%2FzU4%3D",
      "oauth_signature_method" => "HMAC-SHA1", "oauth_timestamp" => "1318622958", "oauth_token" => EXAMPLE["access_token"], "oauth_version" => "1.0" }
    assert_equal "OAuth " + expected.map { |name, value| %(#{name}="#{value}") }.join(", "), header
  end

  test "it lists five tools, reads run at once with the untrusted-data line, and a post asks every time with no Always, even approving everything" do
    assert_equal %w[ get_me mentions search_recent get_post create_post ], @connector.reload.tools.pluck("name")
    tools = @agent.reload.conversation.tools.grep(Tool::Mcp).index_by { it.listing["name"] }
    reads = tools.values_at("get_me", "mentions", "search_recent", "get_post")
    assert reads.all? { it.asks.nil? }
    assert reads.drop(1).all? { it.description.include?(McpServer::X::DATA) }
    assert_not tools.key?("delete_post")

    conversation = @agent.conversation
    with_setting(:app, :approve_everything, true) do
      post = receive(conversation, "mcp__x__create_post", { "text" => "Tuesday." }, "c1")
      assert post.awaiting_person?, "a post shows its approval card"
      assert_empty post.always_choices, "and offers no Always"
      assert_not receive(conversation, "mcp__x__get_me", {}, "c2").awaiting_person?
    end
  end

  test "mentions are signed, ask for the authors, and come back with their usernames" do
    mentions = stub_request(:get, "#{API}/users/42/mentions")
      .with(query: hash_including("max_results" => "100", "since_id" => "7", "expansions" => "author_id"),
            headers: { "Authorization" => /\AOAuth oauth_consumer_key="ck-4417", .*oauth_signature="[^"]+", .*oauth_token="at-3318"/ })
      .to_return(json(data: [ { id: "9", text: "@maya hello", author_id: "5", conversation_id: "9", public_metrics: { like_count: 1 } } ],
        includes: { users: [ { id: "5", username: "sam", name: "Sam" } ] }, meta: { newest_id: "9" }))

    result = call("mentions", "since_id" => "7", "max_results" => 500)

    assert_requested mentions
    assert_equal({ "posts" => [ { "id" => "9", "author" => "@sam (Sam)", "text" => "@maya hello", "conversation_id" => "9", "metrics" => { "like_count" => 1 } } ],
      "newest_id" => "9" }, result["structuredContent"])
  end

  test "a post sends its reply and quote, and only those" do
    created = stub_request(:post, "#{API}/tweets")
      .with(body: { text: "Agreed.", reply: { in_reply_to_tweet_id: "9" }, quote_tweet_id: "8" }.to_json)
      .to_return(json(data: { id: "10", text: "Agreed." }).merge(status: 201))

    result = call("create_post", "text" => "Agreed.", "reply_to" => "9", "quote_post_id" => "8")

    assert_requested created
    assert_equal({ "id" => "10", "text" => "Agreed." }, result["structuredContent"])
  end

  test "a spending cap or a rate limit reads as X's status and title, with when it resets" do
    stub_request(:get, %r{\A#{API}/tweets/search/recent}).to_return(
      { status: 402, headers: { "Content-Type" => "application/problem+json" },
        body: { title: "Payment Required", detail: "Your account has reached its spending cap." }.to_json },
      { status: 429, headers: { "Content-Type" => "application/json", "x-rate-limit-reset" => "1762797600" },
        body: { title: "Too Many Requests", detail: "Too Many Requests", type: "about:blank", status: 429 }.to_json },
      { status: 503, headers: { "Content-Type" => "text/html" }, body: "<html>down</html>" })

    capped, limited, down = 3.times.map { call("search_recent", "query" => "from:sam") }

    assert capped["isError"]
    assert_equal "X answered 402 Payment Required: Your account has reached its spending cap.", capped.dig("content", 0, "text")
    assert_equal "X answered 429 Too Many Requests: Too Many Requests. It resets at 18:00 UTC.", limited.dig("content", 0, "text")
    assert_match "X answered 503", down.dig("content", 0, "text")
  end

  test "a connector needs all four values, and none of them reaches the log" do
    missing = @agent.user.mcp_servers.build(name: "x2", url: API, token: McpServer::X.token(KEYS.except("access_secret")))
    assert_not missing.valid?
    assert_match "needs X's four values", missing.errors.full_messages.to_sentence

    stub_request(:get, %r{\A#{API}/tweets\?}).to_return(json(data: [ { id: "9", text: "hi" } ]))
    log = StringIO.new
    Rails.logger.broadcast_to(capture = ActiveSupport::Logger.new(log))
    call("get_post", "ids" => [ "9" ])
    @connector.refresh
    assert_match "mcp_servers", log.string, "the queries were logged"
    assert_no_match Regexp.union(KEYS.values), log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture) if capture
  end

  private
    def call(tool, arguments = {}) = @connector.call_tool(tool, arguments)

    def receive(conversation, tool, arguments, call_id)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
      conversation.invocations.find_by!(call_id: call_id)
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
end
