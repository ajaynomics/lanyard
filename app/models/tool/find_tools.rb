# The connectors an agent searches instead of loading (McpServer#loaded off):
# their tools stay out of every request, and this one tool, whose description
# names them, finds the few that fit. The agent calls one with use_tool; a
# tool it calls is activated on the conversation (Conversation#activate) and
# from the person's next message is one of its own tools, as pi's tool_search
# makes a match one. Only what it calls: a find for reading must not leave
# the tools that write declared.
# Like Tool::Mcp, an object rather than a class: it is made from the
# conversation's connectors.
class Tool::FindTools
  RESULTS = 5

  attr_reader :tools

  # tools: the searchable connectors' Tool::Mcp; declared: the names of those
  # already the agent's own tools (Agent#tools).
  def initialize(tools, declared: [])
    @tools, @declared = tools, declared
  end

  def tool_name = "find_tools"

  def description
    connectors = tools.group_by(&:server).map do |server, its|
      names = its.map { it.listing["name"] }
      "#{server.name} (#{names.first(8).join(', ')}#{", and #{names.size - 8} more" if names.size > 8})"
    end
    "Find tools on connectors that aren't loaded: describe what you want to do in a few words. Returns the best " \
      "matches with their inputs; call one with use_tool. Connectors: #{connectors.join('; ')}."
  end

  def schema
    { "type" => "object", "additionalProperties" => false, "required" => [ "query" ], "properties" => {
      "query" => { "type" => "string", "minLength" => 1, "maxLength" => 200, "description" => "What the tool should do, e.g. \"search email\"." },
      "connector" => { "type" => "string", "enum" => tools.map { it.server.name }.uniq, "description" => "Only this connector's tools." } } }
  end

  def declaration = { name: tool_name, description: description, parameters: schema }

  def errors_for(values) = JSONSchemer.schema(schema).validate(values).map { it["error"] }

  def asks = nil
  def effect = :database

  def new(invocation) = Call.new(invocation, self)

  # The best few by the query's words in each tool's name and description, a
  # word in the name counting most; nothing matching lists every name.
  def search(query, connector: nil)
    candidates = tools.select { connector.nil? || it.server.name == connector }
    words = query.downcase.scan(/[a-z0-9]+/).reject { it.size < 2 }
    scored = candidates.map do |tool|
      name, text = tool.listing["name"].to_s.downcase, tool.description.downcase
      [ tool, words.sum { |word| (name.include?(word) ? 3 : 0) + text.scan(word).size } ]
    end
    found = scored.select { it.last.positive? }.sort_by { -it.last }.first(RESULTS).map(&:first)
    return { tools: [], none_matched: "Nothing matched. Its tools are: #{candidates.map(&:tool_name).join(', ')}" } if found.none?
    yours, others = found.partition { @declared.include?(it.tool_name) }
    { tools: others.map(&:declaration), already_yours: yours.map(&:tool_name).presence,
      how: "Call one of `tools` with use_tool now. Each one you call becomes one of your own tools, under the same name, from the " \
        "person's next message; then call it directly.#{" Those in `already_yours` are your tools already: call them directly by name, not with use_tool." if yours.any?}" }.compact
  end

  class Call < Tool
    def initialize(invocation, finder)
      super(invocation)
      @finder = finder
    end

    def call(query:, connector: nil) = @finder.search(query, connector:)
  end
end
