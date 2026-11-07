class Agent < ApplicationRecord
  # Every level pi-ai knows, in order, as people read them. Which of them a
  # model supports is pi-ai's fact (ModelCatalog); the sidecar runs a model at
  # its nearest supported level, so a level is never a reason to refuse an agent.
  THINKING_LEVEL_NAMES = { "off" => "Off", "minimal" => "Minimal", "low" => "Low", "medium" => "Medium",
                           "high" => "High", "xhigh" => "Extra high", "max" => "Maximum" }.freeze
  THINKING_LEVELS = THINKING_LEVEL_NAMES.keys.freeze
  TOOL_LIMIT = 64 # the most the sidecar installs for one agent (agent/runtime.mjs)
  # The sidecar's built-in abilities, as the agent's settings describe them. Not
  # tools: Rails has no code for them, it only says whether the agent has them.
  CAPABILITY_DESCRIPTIONS = {
    "codemode" => [ "Code", "Writes and runs short scripts that call several tools at once." ],
    "subagents" => [ "Helpers", "Hands a self-contained piece of work to a helper that reports back." ],
    "web_search" => [ "Web search", "Searches the web and cites its sources." ]
  }.freeze

  belongs_to :user
  has_many :revisions, dependent: :delete_all
  has_many :conversations, dependent: :destroy
  has_many :notes, dependent: :delete_all
  has_one :computer, dependent: :destroy
  # Its identity on Concourse, when it has one.
  has_one :concourse_agent, dependent: :destroy
  has_many :peer_tasks, through: :conversations
  has_many :skills, -> { order(:name) }, dependent: :delete_all
  has_many :prompts, -> { order(:name) }, dependent: :delete_all

  validates :name, :instructions, presence: true
  validates :model, inclusion: { in: ->(_) { models } }
  validates :thinking_level, inclusion: { in: THINKING_LEVELS }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) + %w[ UTC ] }
  validate :tools_are_catalogued, :capabilities_are_allowed
  validate :tools_fit

  after_save :record_revision, if: -> { saved_change_to_instructions? || saved_change_to_model? || saved_change_to_tool_names? || saved_change_to_capabilities? }

  # The model routes the sidecar will run, per environment (config/pi_durable.yml).
  def self.models
    DurableAssistants.config(:pi_durable, :models, default: [])
  end

  # The capabilities an agent may have here (config/pi_durable.yml).
  def self.capability_names
    DurableAssistants.config(:pi_durable, :capabilities, default: [])
  end

  # A starter agent's reviewed defaults: config/agents/<name>/agent.yml and its
  # instructions.md. The created record is then the live agent.
  def self.starter(name)
    directory = Rails.root.join("config/agents", name.to_s)
    settings = YAML.safe_load_file(directory.join("agent.yml"))
    { name: settings.fetch("name"), tool_names: settings.fetch("tools"),
      model: DurableAssistants.config(:pi_durable, :default_model, default: settings.fetch("model")),
      thinking_level: settings.fetch("thinking_level", "medium"), time_zone: settings.fetch("time_zone", "UTC"),
      capabilities: settings.fetch("capabilities"),
      instructions: directory.join("instructions.md").read.strip }
  end

  # The tool classes this agent may call, the concourse_ tools when it is on
  # Concourse, then the connectors' tools: by
  # default its owner's, which every conversation gets; a conversation passes its own set
  # (Conversation#connectors). A stored name with no class is refused by
  # validation, and by the ledger if it slipped past. Two outside names that
  # read the same after sanitising keep the first: the sidecar refuses a
  # definition that repeats one.
  def tools(connectors = user.mcp_servers.global.where(enabled: true))
    own = tool_names.filter_map { Tool::Catalog.find(it) }
    own << Tool::ReadSkill if skills.any?
    own.concat(Tool::Catalog::CONCOURSE) if concourse_agent
    own.concat(Tool::Catalog::SAVED_SIGN_INS) if computer&.on? && computer.sprites? && DurableAssistants::Passbolt.configured?
    (own + connectors.flat_map(&:tool_classes)).uniq(&:tool_name)
  end

  def tool(name)
    tools.find { it.tool_name == name }
  end

  # Everything the sidecar runs a conversation of this agent on, named by its own
  # digest, so the sidecar installs each definition once and never caches a
  # stale one.
  def definition(tools = self.tools)
    body = { instructions: instructions + skills_listing, model: model, thinkingLevel: thinking_level, tools: tools.map(&:declaration),
             capabilities: capabilities, computer: computer&.descriptor }
    body.merge(digest: Agent::Canonical.digest(body))
  end

  # What the person typed, as the model should read it: `/skill:name args`
  # becomes pi's skill block, `/prompt args` its saved prompt. Anything else,
  # a built-in or an unknown `/foo`, goes as typed, as in pi.
  def expand(text)
    command, arguments = text.to_s.match(%r{\A/(\S+)(?:\s+(.*))?\z}m)&.captures
    return text unless command
    if command.start_with?("skill:")
      skills.find_by(name: command.delete_prefix("skill:"))&.invocation(arguments) || text
    else
      prompts.find_by(name: command)&.expand(arguments) || text
    end
  end

  # Kept on every change to what the agent is, its skills and prompts included.
  # History cannot be added later. Restoring a revision is not built yet.
  def record_revision
    revisions.create!(instructions: instructions, model: model, tool_names: tool_names, capabilities: capabilities,
      skills: skills.reload.map(&:snapshot), prompts: prompts.reload.map(&:snapshot))
  end

  # The agent's directory for a local computer; each conversation gets its own
  # directory inside it. Stable for the agent's lifetime: the sidecar binds each
  # conversation to it at admission. "bot-" is the folder's name on disk from
  # before the rename; it is only an identifier now, and changing it would
  # strand every conversation's files.
  def workdir
    Rails.root.join("storage/agent/computers", "bot-#{id}").to_s
  end

  def start_conversation(request_id:)
    durable_id = DurableAssistants::PiDurable::Client.new.conversation(Agent::Access.for(self), request_id).fetch("id").to_s
    conversation = conversations.create_or_find_by!(request_id: request_id) { it.user = user; it.durable_id = durable_id }
    # A sidecar conversation recorded under another request means the store and
    # this database are not from one point in time; refuse rather than guess.
    raise Conversation::Mismatch unless conversation.durable_id == durable_id
    conversation
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise Conversation::Mismatch
  end

  def to_s = name

  private
    def tools_are_catalogued
      (Array(tool_names) - Tool::Catalog.names).each { errors.add(:tool_names, "includes #{it}, which is not a tool") }
    end

    def capabilities_are_allowed
      errors.add(:capabilities, "repeat one") if Array(capabilities).uniq.size != Array(capabilities).size
      (Array(capabilities) - Agent.capability_names).each { errors.add(:capabilities, "include #{it}, which is not available") }
    end

    def tools_fit
      errors.add(:tool_names, "come to #{tools.size}; an agent can have #{TOOL_LIMIT}") if tools.size > TOOL_LIMIT
    end

    # pi's <available_skills> block (system-prompt.ts formatSkillsForPrompt),
    # names and descriptions only: the bodies are read through read_skill, so
    # the instructions stay short and a skill's edit reaches the next reply.
    def skills_listing
      return "" if skills.empty?
      entries = skills.map do |skill|
        "  <skill>\n    <name>#{skill.name.encode(xml: :text)}</name>\n    <description>#{skill.description.encode(xml: :text)}</description>\n  </skill>"
      end
      [ "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Use the read_skill tool to load a skill when the task matches its description.", "",
        "<available_skills>", *entries, "</available_skills>" ].join("\n")
    end
end
