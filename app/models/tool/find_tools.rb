# The connectors an agent looks up rather than carries (lookup, not core for
# it: Agent#core?), and its built-ins outside the core (Tool::Catalog::CORE):
# their tools stay out of every request, and this one tool, whose description
# names them, finds the few that fit. The agent calls one
# with use_tool, or from a code mode script, where searchTools() finds them
# too, as tools.<name>. Where the person lets it (Agent#promotes_found_tools),
# a tool it calls through use_tool is activated on the conversation
# (Conversation#activate) and from the person's next message is one of its
# own tools, as pi's tool_search makes a match one. Only what it calls: a
# find for reading must not leave the tools that write declared.
# Like Tool::Mcp, an object rather than a class: it is made from the
# conversation's connectors.
class Tool::FindTools
  RESULTS = 5
  # How a code mode script reaches the same tools (agent/extensions.mjs).
  SCRIPT = ", or from a codemode script, where searchTools() finds them too, as tools.<name>(...)".freeze

  attr_reader :tools

  # tools: the searchable connectors' Tool::Mcp and built-in Tool classes; declared: the names of those
  # already the agent's own tools (Agent#tools); codemode: whether it can
  # call them from a script; promotes: whether one it calls becomes its own.
  def initialize(tools, declared: [], codemode: false, promotes: false)
    @tools, @declared, @codemode, @promotes = tools, declared, codemode, promotes
  end

  def tool_name = "find_tools"

  # Names only the connectors, not their tools: a connector's list of tools
  # changes as it refreshes, and a changed description starts the prompt
  # cache over (docs/prompt-cache.md). Its own looked-up built-ins are named,
  # so it knows they are there; they change only with its settings.
  def description
    "Find tools you look up rather than carry: describe what you want to do in a few words. Returns the best " \
      "matches with their inputs; call one with use_tool#{SCRIPT if @codemode}." +
      (connector_names.any? ? " Connectors: #{connector_names.join('; ')}." : "") +
      (built_in_names.any? ? " Your own: #{built_in_names.join(', ')}." : "")
  end

  def schema
    properties = { "query" => { "type" => "string", "minLength" => 1, "maxLength" => 200, "description" => "What the tool should do, e.g. \"search email\"." } }
    properties["connector"] = { "type" => "string", "enum" => connector_names, "description" => "Only this connector's tools." } if connector_names.any?
    { "type" => "object", "additionalProperties" => false, "required" => [ "query" ], "properties" => properties }
  end

  def connector_names = tools.filter_map { it.try(:connector) }.uniq.sort
  def built_in_names = tools.reject { it.respond_to?(:connector) }.map(&:tool_name).sort

  def declaration = { name: tool_name, description: description, parameters: schema }

  def errors_for(values) = JSONSchemer.schema(schema).validate(values).map { it["error"] }

  def asks = nil
  def effect = :database

  def new(invocation) = Call.new(invocation, self)

  # The best few by the query's words in each tool's name and description, a
  # word in the name counting most; nothing matching lists every name.
  def search(query, connector: nil)
    candidates = tools.select { connector.nil? || it.try(:connector) == connector }
    words = query.downcase.scan(/[a-z0-9]+/).reject { it.size < 2 }
    scored = candidates.map do |tool|
      name, text = (tool.try(:listing)&.dig("name") || tool.tool_name).to_s.downcase, tool.description.downcase
      [ tool, words.sum { |word| (name.include?(word) ? 3 : 0) + text.scan(word).size } ]
    end
    found = scored.select { it.last.positive? }.sort_by { -it.last }.first(RESULTS).map(&:first)
    return { tools: [], none_matched: "Nothing matched. Its tools are: #{candidates.map(&:tool_name).join(', ')}" } if found.none?
    yours, others = found.partition { @declared.include?(it.tool_name) }
    { tools: others.map(&:declaration), already_yours: yours.map(&:tool_name).presence, how: how(yours.any?) }.compact
  end

  # Exactly how to reach what it found: these are not among its own tools.
  def how(yours)
    [ "These aren't among your tools: call one of `tools` with use_tool now, by its name and with arguments that fit its inputs.",
      ("Or, from a codemode script, call it as tools.<name>(...) with the same arguments; searchTools() finds these tools there too." if @codemode),
      ("Each one you call with use_tool becomes one of your own tools, under the same name, from the person's next message; then call it directly." if @promotes),
      ("Those in `already_yours` are your tools already: call them directly by name, not with use_tool." if yours) ].compact.join(" ")
  end

  class Call < Tool
    def initialize(invocation, finder)
      super(invocation)
      @finder = finder
    end

    def call(query:, connector: nil) = @finder.search(query, connector:)
  end
end
