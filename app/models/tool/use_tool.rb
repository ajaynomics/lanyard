# Calls one tool that find_tools found, on a connector that isn't loaded. It is
# that tool in every way that matters: its inputs are checked against its own
# schema, it asks the person first unless the server marks it read-only, and
# it runs through McpServer#call_tool like a loaded one (Tool::Mcp).
class Tool::UseTool
  attr_reader :tools

  # tools: the searchable connectors' Tool::Mcp; declared: the names of those
  # already the agent's own tools, which it no longer offers. A call made
  # before one was declared still runs.
  def initialize(tools, declared: [])
    @tools, @declared = tools, declared
  end

  def tool_name = "use_tool"

  def description
    "Only for a tool find_tools found that is not yet one of your own tools: call it by the name it gave, with arguments " \
      "that fit the inputs it showed. A tool you call this way is one of your own from the person's next message; then call " \
      "it directly. A tool that changes anything waits for the person's approval, as it would if loaded."
  end

  def schema
    { "type" => "object", "additionalProperties" => false, "required" => %w[ name arguments ], "properties" => {
      "name" => { "type" => "string", "enum" => offered.map(&:tool_name), "description" => "The tool's name, as find_tools gave it." },
      "arguments" => { "type" => "object", "description" => "Its inputs." } } }
  end

  def declaration = { name: tool_name, description: description, parameters: schema }

  # Its own shape, then the tool's, before anyone is asked to approve it.
  def errors_for(values)
    own = JSONSchemer.schema(schema).validate(values).map { it["error"] }
    own.presence || target(values["name"]).errors_for(values["arguments"])
  end

  def target(name) = tools.find { it.tool_name == name }

  # Never an empty list, which a model's API would refuse.
  def offered = tools.reject { @declared.include?(it.tool_name) }.presence || tools

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
    def permission_name = invocation.arguments["name"]
    def recipients = @inner&.recipients.to_a

    def call(name:, arguments:) = @inner.call(**arguments.symbolize_keys)
  end
end
