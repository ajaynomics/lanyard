require "test_helper"
require_relative "../test_helpers/agent_test_helper"

require_relative "../test_helpers/mcp_test_helper"

class AgentTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  test "a new person gets the starter agent from the reviewed template, once" do
    alice = create_user(name: "Alice")
    User.sign_in!(sub: "sub-alice", email: "alice@example.com", name: "Alice")

    agent = alice.agents.sole
    assert_equal "Assistant", agent.name
    assert_equal "local/stand-in", agent.model
    assert_includes agent.instructions, "You are a personal assistant"
    assert_equal %w[ current_time remember_note list_notes forget_note ask_person ], agent.tool_names
    assert_equal %w[ codemode subagents web_search ], agent.capabilities
  end

  test "a starter's computer is on for its agents when this environment offers that kind, and absent otherwise" do
    Dir.mktmpdir do |directory|
      starter = Pathname(directory)
      starter.join("instructions.md").write("Hi.")
      settings = { "name" => "Builder", "model" => "local/stand-in", "tools" => [], "capabilities" => [] }

      starter.join("agent.yml").write(settings.merge("computer" => "sprites").to_yaml)
      assert_equal({ provider: "sprites", state: "on" }, Agent.starter(directory)[:computer_attributes])
      assert create_user.agents.create!(Agent.starter(directory)).computer.on?

      starter.join("agent.yml").write(settings.merge("computer" => "moon").to_yaml)
      assert_not Agent.starter(directory).key?(:computer_attributes)
      starter.join("agent.yml").write(settings.to_yaml)
      assert_not Agent.starter(directory).key?(:computer_attributes)
    end
  end

  test "an agent is born with its one thread, which goes by its name; the sidecar admits it later" do
    agent = create_user.agents.sole
    thread = agent.conversation

    assert_equal [ thread ], agent.conversations.to_a
    assert_nil thread.parent_id
    assert_nil thread.durable_id
    assert_equal "Assistant", thread.to_s
    assert_raises(ActiveRecord::RecordNotUnique) { agent.conversations.create!(user: agent.user, request_id: "second") }
  end

  test "capabilities come from the allow-list, once each, and are kept in revisions and the definition" do
    agent = create_user.agents.sole
    assert_equal %w[ codemode subagents web_search ], agent.definition[:capabilities]

    assert_not agent.update(capabilities: %w[ codemode extensions ])
    assert_includes agent.errors[:capabilities].first, "extensions"
    assert_not agent.update(capabilities: %w[ codemode codemode ])

    digest = agent.reload.definition[:digest]
    assert_difference -> { agent.revisions.count } do
      agent.update!(capabilities: %w[ web_search ])
    end
    assert_equal %w[ web_search ], agent.revisions.last.capabilities
    assert_equal %w[ web_search ], agent.definition[:capabilities]
    assert_not_equal digest, agent.definition[:digest]
  end

  test "an agent made without the template gets every capability" do
    agent = create_user.agents.create!(name: "Plain", instructions: "Hi.", model: Agent.models.first)
    assert_equal %w[ codemode subagents web_search ], agent.capabilities
  end

  test "every edit to what the agent is keeps a revision" do
    agent = create_user.agents.sole
    agent.update!(instructions: "Be terse.")
    agent.update!(name: "Renamed")

    assert_equal "Be terse.", agent.revisions.last.instructions
    assert_equal 2, agent.revisions.count
  end

  test "only catalogued tools and allowed models are accepted" do
    agent = create_user.agents.sole

    assert_not agent.update(tool_names: %w[ current_time rm_rf ])
    assert_includes agent.errors[:tool_names].first, "rm_rf"
    assert_not agent.update(model: "someone/else")
  end

  test "every thinking level pi-ai knows is accepted, and nothing else" do
    agent = create_user.agents.sole

    %w[ off minimal low medium high xhigh max ].each { assert agent.update(thinking_level: it), it }
    assert_not agent.update(thinking_level: "extreme")
  end

  test "the definition names itself by its own digest and changes when the agent does" do
    agent = create_user.agents.sole
    definition = agent.definition

    assert_equal Agent::Canonical.digest(definition.except(:digest)), definition[:digest]
    assert_equal %w[ current_time remember_note list_notes forget_note ask_person change_yourself ], definition[:tools].pluck(:name)
    assert_equal false, definition[:tools].first[:parameters]["additionalProperties"]

    agent.update!(instructions: "Different.")
    assert_not_equal definition[:digest], agent.definition[:digest]
  end

  # The same vector is asserted in the sidecar's suite (agent/test/contract.test.mjs).
  test "a definition digest matches the shared vector, the computer's notes file switch included" do
    body = { instructions: "You are Avery.", model: "anthropic/claude-opus-5-5", thinkingLevel: "medium",
             tools: [ { name: "remember_note", description: "Save a note",
                        parameters: { type: "object", properties: { key: { type: "string" } }, required: [ "key" ] } } ],
             capabilities: %w[ codemode subagents web_search ], computer: { provider: "local", notesFile: true } }

    assert_equal "928d71db3571432557027aabdda03d3e997eba2ed571d31f65971c51d8e15fee", Agent::Canonical.digest(body)
  end

  test "every catalogue pattern is valid ECMA-262, the sidecar's regex dialect" do
    patterns = Tool::Catalog::TOOLS.values.flat_map { it.arguments.values }.filter_map { it["pattern"] }

    assert_not_empty patterns
    patterns.each { assert_no_match(/\\[AzZ]|\(\?[<im-]/, it, "Ruby-only syntax in #{it}") }
  end

  test "an agent has at most the sidecar's limit of tools, its MCP servers' included" do
    agent = create_user.agents.sole
    create_mcp_server(agent, tools: Array.new(Agent::TOOL_LIMIT - 6) { mcp_tool("tool_#{it}") })

    assert_equal Agent::TOOL_LIMIT, agent.definition[:tools].size
    server = agent.user.mcp_servers.new(name: "more", url: MCP_URL, tools: [ { "name" => "one" } ])
    assert_not server.valid?
    assert_match(/already has 64/, server.errors.full_messages.to_sentence)
  end

  test "with skills, the instructions list them as pi does and read_skill is a tool; without, neither" do
    agent = create_user.agents.sole
    assert_not_includes agent.definition[:instructions], "<available_skills>"
    assert_not_includes agent.definition[:tools].pluck(:name), "read_skill"

    agent.skills.create!(name: "trip", description: "Plans trips & <routes>.", body: "Secret steps")
    definition = agent.reload.definition

    assert definition[:instructions].start_with?(agent.instructions)
    assert definition[:instructions].end_with?(<<~LISTING.chomp)


      The following skills provide specialized instructions for specific tasks.
      Use the read_skill tool to load a skill when the task matches its description.

      <available_skills>
        <skill>
          <name>trip</name>
          <description>Plans trips &amp; &lt;routes&gt;.</description>
        </skill>
      </available_skills>
    LISTING
    assert_not_includes definition[:instructions], "Secret steps"
    assert_equal "read_skill", definition[:tools].last[:name]
    assert_not_includes Tool::Catalog.names, "read_skill"
    assert_not agent.update(tool_names: agent.tool_names + %w[ read_skill ])
  end

  test "expand turns a skill or a saved prompt into what the model reads, and leaves everything else as typed" do
    agent = create_user.agents.sole
    agent.skills.create!(name: "trip", description: "d", body: "Steps")
    agent.prompts.create!(name: "review", body: "Review $1 then $@")

    assert_equal %(<skill name="trip" location="skill:trip">\nSteps\n</skill>\n\nto Lisbon\nsoon), agent.expand("/skill:trip to Lisbon\nsoon")
    assert_equal %(<skill name="trip" location="skill:trip">\nSteps\n</skill>), agent.expand("/skill:trip")
    assert_equal "Review a.rb then a.rb fast", agent.expand(%(/review a.rb "fast"))
    [ "/skill:nope go", "/foo bar", "/stop", "/name Trip", "review this", " /review x", "/" ].each { assert_equal it, agent.expand(it) }
  end
end
