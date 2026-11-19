# Calls one tool that find_tools found: on a connector that is lookup for the
# agent, or one of its built-ins outside the core (Tool::Catalog::CORE). It is
# that tool in every way that matters: its inputs are checked against its own
# schema, it asks whom and when that tool asks (a connector's unless the
# server marks it read-only), and it runs as that tool does called directly.
class Tool::UseTool
  attr_reader :tools

  # tools: the searchable connectors' Tool::Mcp, all of them, those already
  # the agent's own too: one it calls may become its own, and leaving it out
  # here would change this declaration, which starts the prompt cache over
  # (docs/prompt-cache.md). A call made before one was declared still runs.
  # promotes: whether a tool it calls becomes its own (Agent#promotes_found_tools).
  def initialize(tools, codemode: false, promotes: false)
    @tools, @codemode, @promotes = tools, codemode, promotes
  end

  def tool_name = "use_tool"

  def description
    "Only for a tool find_tools found that is not one of your own tools: call it by the name it gave, with arguments " \
      "that fit the inputs it showed. " +
      (@promotes ? "A tool you call this way is one of your own from the person's next message; then call it directly. " : "") +
      "A tool that changes anything waits for the person's approval, as it would if it were one of your own."
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

  def approval_title(arguments) = target(arguments.to_h["name"]).try(:approval_title, arguments.to_h["arguments"].to_h)
  def approval_note(arguments) = target(arguments.to_h["name"]).try(:approval_note, arguments.to_h["arguments"].to_h)

  def effect = :external

  def new(invocation) = Call.new(invocation, target(invocation.arguments["name"]))

  # The tool it calls is built on the ledger's own row, exactly as it is
  # called directly: it reads its own name and arguments from the call
  # (Tool#arguments, Tool#permission_name), so its approver, its recipients
  # and when it asks are the same either way, while an association, a query or
  # a job argument still gets the real Invocation (#253).
  class Call < Tool
    def initialize(invocation, tool)
      super(invocation)
      @inner = tool&.new(invocation)
    end

    # Gone since find_tools offered it: switched off, removed or made core again.
    def permitted? = @inner.present? && @inner.permitted?

    def asks = @inner&.asks

    # The tool it calls is what a person allows, as if it were called directly.
    def always? = @inner.present? && @inner.always?
    def every_time? = @inner.present? && @inner.every_time?
    def even_approving_everything? = @inner.present? && @inner.even_approving_everything?
    def reaches_others? = @inner.present? && @inner.reaches_others?
    def changes_itself? = @inner.present? && @inner.changes_itself?
    def permission_name = @inner.is_a?(Tool::Mcp::Call) ? @inner.permission_name : invocation.call_name
    def approver = @inner&.approver
    def approval_title(arguments) = @inner.try(:approval_title, arguments.to_h["arguments"].to_h)
    def approval_note(arguments) = @inner.try(:approval_note, arguments.to_h["arguments"].to_h)
    def details(arguments) = @inner.try(:details, arguments.to_h["arguments"].to_h)
    def download(...) = @inner.download(...)
    def recipients = @inner&.recipients.to_a
    def contacts = @inner&.contacts.to_a
    def previews? = @inner.present? && @inner.previews?
    def preview = @inner.preview

    # The sidecar reads files only for a tool's own argument, never inside
    # use_tool's, so they can't arrive. A code mode script calls the tool by
    # its own name, and the files go that way; so does a call of the tool
    # once it is the agent's own (Invocation#begin_work, where it promotes).
    def refusal
      return @inner&.refusal unless @inner.try(:attaching?)
      name = invocation.arguments["name"]
      script = (" Or call it from a codemode script as tools.#{name}(...), with the same attachments." if agent.codemode?)
      if conversation.declares?(name)
        "Files can't go through use_tool, so nothing was sent or saved. #{name} is one of your tools from the person's next " \
          "message: call it directly then, with the same attachments.#{script}"
      else
        "Files can't go through use_tool, so nothing was sent or saved. Ask the person to make its connector core for you, " \
          "in your Tools settings, then call #{name} directly with the same attachments.#{script}"
      end
    end

    def call(name:, arguments:) = @inner.call(**arguments.symbolize_keys)
  end
end
