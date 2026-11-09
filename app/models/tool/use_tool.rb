# Calls one tool that find_tools found, on a connector that isn't loaded. It is
# that tool in every way that matters: its inputs are checked against its own
# schema, it asks the person first unless the server marks it read-only, and
# it runs through McpServer#call_tool like a loaded one (Tool::Mcp).
class Tool::UseTool
  attr_reader :tools

  # tools: the searchable connectors' Tool::Mcp, all of them, those already
  # the agent's own too: one it calls becomes its own, and leaving it out
  # here would change this declaration, which starts the prompt cache over
  # (docs/prompt-cache.md). A call made before one was declared still runs.
  def initialize(tools)
    @tools = tools
  end

  def tool_name = "use_tool"

  def description
    "Only for a tool find_tools found that is not yet one of your own tools: call it by the name it gave, with arguments " \
      "that fit the inputs it showed. A tool you call this way is one of your own from the person's next message; then call " \
      "it directly. A tool that changes anything waits for the person's approval, as it would if loaded."
  end

  def schema
    { "type" => "object", "additionalProperties" => false, "required" => %w[ name arguments ], "properties" => {
      "name" => { "type" => "string", "enum" => tools.map(&:tool_name).sort, "description" => "The tool's name, as find_tools gave it." },
      "arguments" => { "type" => "object", "description" => "Its inputs." } } }
  end

  def declaration = { name: tool_name, description: description, parameters: schema }

  # Its own shape, then the tool's, before anyone is asked to approve it.
  def errors_for(values)
    own = JSONSchemer.schema(schema).validate(values).map { it["error"] }
    own.presence || target(values["name"]).errors_for(values["arguments"])
  end

  def target(name) = tools.find { it.tool_name == name }

  def effect = :external

  def new(invocation) = Call.new(invocation, target(invocation.arguments["name"]))

  class Call < Tool
    def initialize(invocation, tool)
      super(invocation)
      @inner = tool&.new(invocation)
    end

    # Gone since find_tools offered it: switched off, removed or loaded again.
    def permitted? = @inner.present?

    def asks = @inner&.asks

    # The tool it calls is what a person allows, as if it were called directly.
    def always? = @inner.present? && @inner.always?
    def every_time? = @inner.present? && @inner.every_time?
    def even_approving_everything? = @inner.present? && @inner.even_approving_everything?
    def permission_name = invocation.arguments["name"]
    def recipients = @inner&.recipients.to_a
    def previews? = @inner.present? && @inner.previews?
    def preview = @inner.preview

    def call(name:, arguments:) = @inner.call(**arguments.symbolize_keys)
  end
end
