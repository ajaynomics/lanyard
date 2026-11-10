# An X account, read and posted to through X's API v2 (docs/connectors.md),
# answered in Rails as Google's and IMAP's are. It signs in as the app's
# owner with the four values X's developer console gives (OAuth 1.0a user
# context), kept as JSON in the connector's encrypted token: no sign-in page,
# no callback. No deleting, and no polling: a call is made only when the
# agent makes one.
class McpServer::X
  URL = "https://api.x.com/2".freeze
  KEYS = %w[ consumer_key consumer_secret access_token access_secret ].freeze
  TIMEOUT = 15
  ID = { "type" => "string", "pattern" => "^[0-9]{1,19}$" }.freeze
  READ = { "readOnlyHint" => true }.freeze
  DATA = McpServer::Google::DATA
  POST_FIELDS = "created_at,conversation_id,author_id,referenced_tweets,public_metrics".freeze

  def self.count(description, min, max) = { "type" => "integer", "minimum" => min, "maximum" => max, "description" => description }
  def self.schema(required = [], **properties) = { "type" => "object", "required" => required, "properties" => properties.stringify_keys }

  TOOLS = [
    [ "get_me", READ, "The account this connector posts as: its id, username and name.", schema ],
    [ "mentions", READ, "Posts that mention the account, newest first, with each one's author. Pass since_id (a newest_id from before) " \
      "for only the newer ones." + DATA,
      schema(since_id: ID.merge("description" => "Only posts after this one."), max_results: count("How many, 5 to 100; 10 when left out.", 5, 100)) ],
    [ "search_recent", READ, "Search the last seven days of posts, newest first, with X's search operators (from:, to:, -is:retweet). " \
      "conversation_id:<id> gives the replies in a thread." + DATA,
      schema([ "query" ], query: { "type" => "string", "minLength" => 1, "maxLength" => 512, "description" => "What to find." },
        since_id: ID.merge("description" => "Only posts after this one."), max_results: count("How many, 10 to 100; 10 when left out.", 10, 100)) ],
    [ "get_post", READ, "Posts by id, each with its author, time, thread and public counts (likes, reposts, replies, quotes)." + DATA,
      schema([ "ids" ], ids: { "type" => "array", "items" => ID, "minItems" => 1, "maxItems" => 100, "description" => "The posts' ids." }) ],
    [ "create_post", { "readOnlyHint" => false, "destructiveHint" => false }, "Post as the account: a new post, a reply, or a quote. " \
      "It asks the person every time. Quoting needs an X plan that allows it.",
      schema([ "text" ], text: { "type" => "string", "minLength" => 1, "maxLength" => 25_000, "description" => "What to post." },
        reply_to: ID.merge("description" => "Reply to this post."), quote_post_id: ID.merge("description" => "Quote this post.")) ]
  ].map { |name, annotations, description, input|
    { "name" => name, "annotations" => annotations, "description" => description, "input_schema" => input, "asks_every_time" => name == "create_post" }
  }.freeze

  class Refused < StandardError; end

  def self.x?(url) = url.to_s.start_with?(URL)
  def self.token(values) = values.to_h.stringify_keys.slice(*KEYS).transform_values { it.to_s.strip }.to_json

  # The OAuth 1.0a Authorization header (RFC 5849, HMAC-SHA1). params are
  # the query's or a form body's; a JSON body is not signed.
  def self.authorization(method, url, credentials, params = {}, nonce: SecureRandom.hex(16), timestamp: Time.now.to_i)
    oauth = { "oauth_consumer_key" => credentials["consumer_key"], "oauth_nonce" => nonce, "oauth_signature_method" => "HMAC-SHA1",
              "oauth_timestamp" => timestamp.to_s, "oauth_token" => credentials["access_token"], "oauth_version" => "1.0" }
    pairs = oauth.merge(params.to_h.stringify_keys).map { |key, value| "#{escape(key)}=#{escape(value)}" }.sort.join("&")
    base = [ method.to_s.upcase, escape(url), escape(pairs) ].join("&")
    key = "#{escape(credentials["consumer_secret"])}&#{escape(credentials["access_secret"])}"
    signed = oauth.merge("oauth_signature" => Base64.strict_encode64(OpenSSL::HMAC.digest("SHA1", key, base)))
    "OAuth " + signed.sort.map { |name, value| %(#{escape(name)}="#{escape(value)}") }.join(", ")
  end

  def self.escape(value) = value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { format("%%%02X", it.ord) }

  def initialize(server)
    @server = server
  end

  def credentials = JSON.parse(@server.token.to_s).slice(*KEYS)

  def call_tool(name, arguments)
    args = arguments.to_h.stringify_keys
    content = case name
    when "get_me" then me
    when "mentions" then posts(get("/users/#{me[:id]}/mentions", listing(args, 5)))
    when "search_recent" then posts(get("/tweets/search/recent", listing(args, 10).merge("query" => args["query"].to_s)))
    when "get_post" then posts(get("/tweets", fields.merge("ids" => Array(args["ids"]).join(","))))
    when "create_post" then post(args)
    else raise Refused, "#{@server} has no tool #{name}."
    end
    { "structuredContent" => content.as_json, "content" => [ { "type" => "text", "text" => content.to_json } ] }
  rescue Refused => refused
    { "isError" => true, "content" => [ { "type" => "text", "text" => refused.message.truncate(500) } ] }
  end

  private
    def me
      Rails.cache.fetch([ "x-me", @server.id, Digest::SHA256.hexdigest(@server.token.to_s) ], expires_in: 1.day) do
        get("/users/me")["data"].then { { id: it["id"], username: it["username"], name: it["name"] } }
      end
    end

    def fields = { "tweet.fields" => POST_FIELDS, "expansions" => "author_id", "user.fields" => "username,name" }

    def listing(args, least)
      fields.merge("max_results" => (args["max_results"] || 10).to_i.clamp(least, 100).to_s, "since_id" => args["since_id"].presence).compact
    end

    def post(args)
      body = { text: args["text"].to_s, reply: ({ in_reply_to_tweet_id: args["reply_to"] } if args["reply_to"].present?),
               quote_tweet_id: args["quote_post_id"].presence }.compact
      request(:post, "/tweets", body: body)["data"].then { { id: it["id"], text: it["text"] } }
    end

    # Each post with its author's username; newest_id is the since_id for next time.
    def posts(json)
      users = Array(json.dig("includes", "users")).index_by { it["id"] }
      found = Array(json["data"]).map do |post|
        { id: post["id"], author: users[post["author_id"]]&.then { "@#{it["username"]} (#{it["name"]})" } || post["author_id"],
          text: post["text"], created_at: post["created_at"], conversation_id: post["conversation_id"],
          reply_to: Array(post["referenced_tweets"]).find { it["type"] == "replied_to" }&.dig("id"), metrics: post["public_metrics"] }.compact
      end
      { posts: found, newest_id: json.dig("meta", "newest_id"), not_found: Array(json["errors"]).map { it["detail"] }.presence }.compact
    end

    def get(path, query = {}) = request(:get, path, query: query)

    def request(method, path, query: {}, body: nil)
      url = "#{URL}#{path}"
      uri = URI(query.any? ? "#{url}?#{query.map { |key, value| "#{self.class.escape(key)}=#{self.class.escape(value)}" }.join("&")}" : url)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri, "Accept" => "application/json",
        "Authorization" => self.class.authorization(method, url, credentials, query))
      request.content_type, request.body = "application/json", body.to_json if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
      json = parse(response.body)
      response.is_a?(Net::HTTPSuccess) ? json : raise(Refused, problem(response, json))
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => failure
      raise McpServer::Unreachable, "Could not reach X: #{failure.class.name.demodulize}"
    end

    def parse(body)
      JSON.parse(body.presence || "{}").then { it.is_a?(Hash) ? it : {} }
    rescue JSON::ParserError
      {}
    end

    # X's status and title, its detail, and for a rate limit when it resets:
    # a spending cap (402) or a limit (429) reads as what it is.
    def problem(response, json)
      detail = json["detail"].presence || Array(json["errors"]).map { it["message"] || it["detail"] }.compact.join("; ")
      reset = response["x-rate-limit-reset"].to_i.nonzero?&.then { " It resets at #{Time.at(it).utc.strftime('%H:%M')} UTC." }
      "X answered #{response.code} #{json["title"].presence || response.message}#{": #{detail}" if detail.present?}".delete_suffix(".") + ".#{reset}"
    end
end
