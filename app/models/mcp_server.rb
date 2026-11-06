# A remote MCP server whose tools a bot may use (docs/design/PARITY.md §7).
# Rails is the client, through the official `mcp` gem. A refresh lists the
# server's tools and keeps them here, so building a bot's definition never
# waits on the network; each call then goes out through the Invocation ledger.
class McpServer < ApplicationRecord
  # Room for `mcp__<name>__` and a readable tool name inside the sidecar's 64.
  NAME = /\A[a-z][a-z0-9_]{0,19}\z/
  LOCAL_HOSTS = %w[ localhost 127.0.0.1 ::1 [::1] ].freeze
  TIMEOUT = 30 # seconds, for each request and any stream the server holds open

  # Anything the server or the wire can go wrong with, as one plain message.
  class Unreachable < StandardError; end
  FAILURES = [ MCP::Client::RequestHandlerError, MCP::Client::ServerError, MCP::Client::ValidationError,
               MCP::Client::PaginationLimitError, MCP::Client::InputRequiredError, Faraday::Error, JSON::ParserError ].freeze

  belongs_to :bot
  encrypts :token

  # The bot's settings page shows the listed tools; a refresh redraws it.
  broadcasts_refreshes_to :bot

  normalizes :token, with: -> { it.strip.presence }
  validates :name, format: { with: NAME, message: "must start with a letter and use only a-z, 0-9 and _ (up to 20)" },
    uniqueness: { scope: :bot_id }
  validate :url_is_https
  validate :fits_the_bot, if: :tools_changed?

  # Lists the server's tools and keeps them, or keeps why it could not. Network
  # work, so it runs in McpServerRefreshJob, never inside a transaction.
  def refresh
    listed = connect { it.tools }.map do
      { "name" => it.name, "description" => it.description.to_s, "input_schema" => it.input_schema || {},
        "annotations" => it.annotations || {} }
    end
    update!(tools: listed, refreshed_at: Time.current, refresh_error: nil)
  rescue Unreachable => problem
    record_problem problem.message
  rescue ActiveRecord::RecordInvalid
    record_problem errors.full_messages.to_sentence
  end

  def refreshing? = refreshed_at.nil?

  # One call to one of its tools; the raw JSON-RPC result, for Tool::Mcp to read.
  def call_tool(name, arguments)
    connect { it.call_tool(name: name, arguments: arguments) }.fetch("result") { raise Unreachable, "#{self.name} sent no result." }
  end

  # Its tools, each answering like a Tool class.
  def tool_classes = tools.map { Tool::Mcp.new(self, it) }

  def to_s = name

  private
    def connect
      transport = MCP::Client::HTTP.new(url: url, headers: token ? { "Authorization" => "Bearer #{token}" } : {},
        max_reconnection_wait: TIMEOUT) { it.options.timeout = TIMEOUT }
      client = MCP::Client.new(transport: transport)
      # The 2025 handshake every current server speaks; :auto would probe the
      # 2026 discovery first and fall back to this anyway.
      client.connect(client_info: { name: "durable-assistants", version: "1" }, mode: :legacy)
      yield client
    rescue *FAILURES => failure
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    ensure
      close transport
    end

    # Ending the session is a courtesy; a server that refuses it changes nothing here.
    def close(transport)
      transport&.close
    rescue *FAILURES
      nil
    end

    def record_problem(message)
      restore_attributes
      update!(refresh_error: message, refreshed_at: Time.current)
    end

    # The token goes in a header, so plain http is allowed only to this machine.
    def url_is_https
      uri = URI.parse(url.to_s)
      return if uri.is_a?(URI::HTTPS) && uri.host.present?
      return if uri.is_a?(URI::HTTP) && LOCAL_HOSTS.include?(uri.host)
      errors.add(:url, "must start with https://")
    rescue URI::InvalidURIError
      errors.add(:url, "is not a web address")
    end

    # The sidecar refuses a definition with more than its limit of tools.
    def fits_the_bot
      others = bot.tool_names.size + bot.mcp_servers.excluding(self).sum { it.tools.size }
      if others + tools.size > Bot::TOOL_LIMIT
        errors.add(:base, "#{name} offers #{tools.size} tools; #{bot} can have #{Bot::TOOL_LIMIT} in all and already has #{others}")
      end
    end
end
