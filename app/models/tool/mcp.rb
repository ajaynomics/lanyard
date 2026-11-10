# One tool on an agent's MCP server. It answers the messages a Tool class answers
# (tool_name, declaration, errors_for, asks, effect, new), so Agent#tools lists it
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

  # The connector find_tools names it under (Tool::Mcp::Group names its kind).
  def connector = server.name

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

  # A tool of this app's own listing may ask a person every time, even where the
  # install approves everything (McpServer::Google): what a server lists cannot.
  def even_approving_everything? = server.own_listing? && listing["asks_every_time"] == true
  def every_time? = even_approving_everything?
  def always? = !every_time?
  # An event tool that asks every time when a call reaches other people (McpServer::Google#reaches_others?).
  def asks_with_guests? = server.own_listing? && listing["asks_with_guests"] == true
  # A share that asks every time when it reaches outside the account's own domain.
  def asks_outside? = server.own_listing? && listing["asks_outside"] == true
  def asks_every_time_for?(arguments) =
    even_approving_everything? || ((asks_with_guests? || asks_outside?) && McpServer::Google.new(server).reaches_others?(listing["name"], arguments))

  def label = "#{listing['name'].to_s.humanize(capitalize: false)} (#{server})"

  # The call leaves this database, so the ledger records the row before it runs.
  def effect = :external

  def new(invocation) = Call.new(invocation, self)

  # One call of the tool, made for an invocation.
  class Call < Tool
    def initialize(invocation, tool)
      super(invocation)
      @tool = tool
    end

    def asks = @tool.asks
    def even_approving_everything? = @tool.asks_every_time_for?(arguments)
    # A draft's id says nothing of what it holds, and the agent can change the
    # draft after the card is made, so the card shows the draft itself.
    def previews? = @tool.server.google.present? && @tool.listing["name"] == "send_draft"
    def preview = McpServer::Google.new(@tool.server).preview(@tool.listing["name"], arguments)
    def every_time? = even_approving_everything?
    def always? = !every_time?
    # The connector's own tool, called directly, through use_tool, or as one
    # account of a Tool::Mcp::Group: an "Always" stays with that connector.
    def permission_name = @tool.tool_name

    def call(**arguments)
      result = @tool.server.call_tool(@tool.listing["name"], arguments, conversation: conversation)
      raise Refusal, "#{@tool.tool_name} failed: #{text_of(result).presence || 'no reason given'}".truncate(1_000) if result["isError"]
      result["structuredContent"].is_a?(Hash) ? result["structuredContent"] : { text: text_of(result) }
    # Only the person can sign in, so the agent is told to ask them rather than try again.
    rescue McpServer::SignInNeeded
      raise Refusal, "#{@tool.server} needs the person to sign in again, on its Connectors page. Tell them; don't retry until they have."
    rescue McpServer::Unreachable => problem
      raise Refusal, problem.message
    end

    private
      # This call's arguments: under use_tool (Tool::UseTool), those it passes on.
      def arguments = invocation.tool_name == "use_tool" ? invocation.arguments["arguments"].to_h : invocation.arguments

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
