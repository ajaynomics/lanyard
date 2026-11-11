# One Google tool across an agent's connectors of one kind (McpServer::Google.kind):
# two Gmail accounts give one search_threads, named mcp__gmail__search_threads,
# with an account argument saying which. The connectors don't change: each
# keeps its own sign-in, scope and switches, and a call runs, asks, and is
# allowed "Always" as that connector's own tool (Tool::Mcp), so an answer for
# one account never covers another.
class Tool::Mcp::Group
  attr_reader :kind, :servers, :members

  # servers: the group's connectors, in name order; members: the Tool::Mcp
  # of one listing on those that offer it (their scope allows it, and it is
  # switched on), in the same order.
  def initialize(kind, servers, members)
    @kind, @servers, @members = kind, servers, members
  end

  def listing = members.first.listing
  def connector = kind.to_s
  def tool_name = "mcp__#{kind}__#{members.first.tool_name.delete_prefix("mcp__#{members.first.server.name}__")}"
  def description = members.first.description

  # The connector's name stands for its account: the person chose it, and it
  # is known without asking Google while each message's tools are built.
  def schema
    base = members.first.schema
    account = { "type" => "string", "enum" => servers.map(&:name),
      "description" => "Which account's connector: #{servers.map(&:name).join(', ')}. #{default} when left out." }
    base.merge("properties" => base["properties"].merge("account" => account))
  end

  def declaration = { name: tool_name, description: description, parameters: schema, files: members.first.files_declaration }.compact
  def files_limits = members.first.files_limits

  def errors_for(values)
    values = values.to_h
    return [ "#{values['account']} can't #{listing['name']}: its sign-in doesn't allow it, or it is switched off there" ] unless member(values)
    JSONSchemer.schema(schema, regexp_resolver: "ecma").validate(values).map { it["error"] }
  end

  # The call's connector: the account it names, or the first that has the tool.
  def member(arguments)
    name = arguments.to_h.stringify_keys["account"].presence || default
    members.find { it.server.name == name }
  end

  def asks = members.first.asks
  def asks_with_guests? = members.first.asks_with_guests?
  def asks_outside? = members.first.asks_outside?
  def even_approving_everything? = members.first.even_approving_everything?
  def every_time? = even_approving_everything?
  def always? = !every_time?
  def label = "#{listing['name'].to_s.humanize(capitalize: false)} (#{kind})"
  def effect = :external

  # The card says which account a call will act as.
  def approval_title(arguments)
    "Allow #{listing['name'].to_s.humanize(capitalize: false)} as #{member(arguments)&.server&.name || arguments.to_h['account']}?"
  end

  def new(invocation)
    arguments = invocation.tool_name == "use_tool" ? invocation.arguments["arguments"].to_h : invocation.arguments
    (tool = member(arguments)) ? Call.new(invocation, tool) : Gone.new(invocation)
  end

  # A call of the chosen connector's own tool; account is this group's, not Google's.
  class Call < Tool::Mcp::Call
    def call(**arguments) = super(**arguments.except(:account))
  end

  # The account was signed out, switched off or removed since the call was made.
  class Gone < Tool
    def permitted? = false
    def asks = nil
  end

  private
    def default = members.first.server.name
end
