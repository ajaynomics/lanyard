# Connectors pasted in pi's own mcp.json shape (docs/connectors.md): either
# `{ "mcpServers": { "<name>": { … } } }` or just `{ "<name>": { … } }`. Each
# entry becomes the attributes of one McpServer, or a plain sentence saying
# why it cannot.
#
# Remote (URL) servers only: a `command` would run a program on this machine,
# which is a separate decision. Values are taken literally; pi's `${VAR}` and
# `!command` substitutions are refused, since there is no environment of the
# person's here to read them from.
class McpServer::Entry
  class Invalid < StandardError; end

  KEYS = %w[ url type headers oauth enabled description timeout exposure toolExposure ].freeze
  OAUTH_KEYS = %w[ clientId clientSecret scope clientRegistration ].freeze
  SUBSTITUTION = /\$\{|\A\s*!/

  # name => attributes, for every entry in the text.
  def self.parse(text)
    document = JSON.parse(text.to_s)
    servers = document.is_a?(Hash) && document.key?("mcpServers") ? document["mcpServers"] : document
    raise Invalid, "Paste an object of servers by name, as in pi's mcp.json." unless servers.is_a?(Hash) && servers.any?
    servers.to_h { |name, entry| [ name, new(name, entry).attributes ] }
  rescue JSON::ParserError
    raise Invalid, "That isn't JSON. Paste a server entry as in pi's mcp.json."
  end

  def initialize(name, entry)
    @name, @entry = name, entry
  end

  def attributes
    refuse "isn't an object" unless @entry.is_a?(Hash)
    refuse "Only remote (URL) servers for now" if @entry.key?("command")
    refuse "uses #{@entry['type']}; only http servers work here" if @entry.key?("type") && !%w[ http streamable-http ].include?(@entry["type"])
    unknown = @entry.keys - KEYS
    refuse "has #{unknown.to_sentence}, which this app doesn't know" if unknown.any?
    { name: @name, url: @entry["url"], headers: headers, enabled: @entry.fetch("enabled", true) != false }.merge(oauth)
  end

  private
    def headers
      headers = @entry["headers"] || {}
      refuse "has headers that aren't text" unless headers.is_a?(Hash) && headers.values.all?(String)
      literal headers.values
      headers.presence
    end

    def oauth
      oauth = @entry["oauth"] || {}
      refuse "has an oauth setting that isn't an object" unless oauth.is_a?(Hash)
      unknown = oauth.keys - OAUTH_KEYS
      refuse "has oauth #{unknown.to_sentence}, which this app doesn't support" if unknown.any?
      refuse "asks for a client ID metadata document, which a service can't fetch from behind Cloudflare Access" if oauth["clientRegistration"] == "cimd"
      literal [ oauth["clientSecret"] ].compact
      { client_id: oauth["clientId"], client_secret: oauth["clientSecret"], oauth_scope: oauth["scope"] }.compact
    end

    def literal(values)
      refuse "uses ${…} or !command; paste the value itself" if values.any? { it.to_s.match?(SUBSTITUTION) }
    end

    def refuse(reason)
      raise Invalid, "#{@name}: #{reason}."
    end
end
