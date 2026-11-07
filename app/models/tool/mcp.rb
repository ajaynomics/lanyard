# One tool on a bot's MCP server. It answers the messages a Tool class answers
# (tool_name, declaration, errors_for, asks, effect, new), so Bot#tools lists it
# and the Invocation ledger runs it like any other tool.
#
# What the server says about a tool is its claim, not ours: only a tool it marks
# read-only runs at once; the MCP spec reads an unmarked tool as destructive, so
# anything else asks the person first. Its results reach the model as data.
class Tool::Mcp
  NAME_LIMIT = 64
  TEXT_LIMIT = 50_000

  attr_reader :server, :listing

  def initialize(server, listing)
    @server, @listing = server, listing
  end

  # `mcp__<server>__<tool>`, in the sidecar's alphabet and length.
  def tool_name
    prefix = "mcp__#{server.name}__"
    prefix + listing["name"].to_s.downcase.gsub(/[^a-z0-9_]/, "_").first(NAME_LIMIT - prefix.length)
  end

  def description = listing["description"].to_s.truncate(2_000).presence || listing["name"].to_s

  def schema
    input = listing["input_schema"].presence || {}
    input.merge("type" => "object", "properties" => input["properties"] || {})
  end

  def declaration = { name: tool_name, description: description, parameters: schema }

  def errors_for(values)
    JSONSchemer.schema(schema, regexp_resolver: "ecma").validate(values).map { it["error"] }
  rescue JSONSchemer::UnknownRef, JSONSchemer::UnknownFormat, JSONSchemer::UnknownVocabulary, JSONSchemer::InvalidRefResolution,
         JSONSchemer::InvalidRefPointer, JSONSchemer::InvalidRegexpResolution => error
    [ "#{server} described #{listing["name"]} with a schema that cannot be checked (#{error.class.name.demodulize})" ]
  end

  def asks = listing.dig("annotations", "readOnlyHint") == true ? nil : :approval

  # The call leaves this database, so the ledger records the row before it runs.
  def effect = :external

  def new(invocation) = Call.new(invocation, self)

  # One call of the tool, made for an invocation.
  class Call < Tool
    def initialize(invocation, tool)
      super(invocation)
      @tool = tool
    end

    def call(**arguments)
      result = @tool.server.call_tool(@tool.listing["name"], arguments, agent: conversation)
      raise Refusal, "#{@tool.tool_name} failed: #{text_of(result).presence || 'no reason given'}".truncate(1_000) if result["isError"]
      result["structuredContent"].is_a?(Hash) ? result["structuredContent"] : { text: text_of(result) }
    # Only the person can sign in, so the bot is told to ask them rather than try again.
    rescue McpServer::SignInNeeded
      raise Refusal, "#{@tool.server} needs the person to sign in again, on its Connectors page. Tell them; don't retry until they have."
    rescue McpServer::Unreachable => problem
      raise Refusal, problem.message
    end

    private
      # Text as the model reads it; anything else is named rather than inlined.
      def text_of(result)
        Array(result["content"]).map do |block|
          case block["type"]
          when "text" then block["text"].to_s
          when "resource" then block.dig("resource", "text") || "[resource #{block.dig('resource', 'uri')}]"
          else "[#{block['type']} #{block['mimeType']}]".squish
          end
        end.join("\n\n").truncate(TEXT_LIMIT)
      end
  end
end
