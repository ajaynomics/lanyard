class Agent < ApplicationRecord
  # Every level pi-ai knows, in order, as people read them. Which of them a
  # model supports is pi-ai's fact (ModelCatalog); the sidecar runs a model at
  # its nearest supported level, so a level is never a reason to refuse an agent.
  THINKING_LEVEL_NAMES = { "off" => "Off", "minimal" => "Minimal", "low" => "Low", "medium" => "Medium",
                           "high" => "High", "xhigh" => "Extra high", "max" => "Maximum" }.freeze
  THINKING_LEVELS = THINKING_LEVEL_NAMES.keys.freeze
  TOOL_LIMIT = 64 # the most the sidecar installs for one agent (agent/runtime.mjs)
  TOOL_WARNING = 56 # where its settings start saying what to turn off
  # The sidecar's built-in abilities, as the agent's settings describe them. Not
  # tools: Rails has no code for them, it only says whether the agent has them.
  CAPABILITY_DESCRIPTIONS = {
    "codemode" => [ "Code", "Writes and runs short scripts that call several tools at once." ],
    "subagents" => [ "Helpers", "Hands a self-contained piece of work to a helper that reports back." ],
    "web_search" => [ "Web search", "Searches the web and cites its sources." ]
  }.freeze

  belongs_to :user
  has_many :revisions, dependent: :delete_all
  # An agent is one thread (CONTEXT.md): `conversation` is it, and its
  # branches, alternatives taken from one of its messages, are the rest.
  has_many :conversations, dependent: :destroy
  has_one :conversation, -> { where(parent_id: nil) }, inverse_of: :agent
  has_many :notes, dependent: :delete_all
  has_many :routines, dependent: :delete_all
  has_one :campfire_bot, dependent: :destroy
  has_one :computer, dependent: :destroy
  # Its identity on Concourse, when it has one.
  has_one :concourse_agent, dependent: :destroy
  has_many :peer_tasks, through: :conversations
  has_many :skills, -> { order(:name) }, dependent: :delete_all
  has_many :prompts, -> { order(:name) }, dependent: :delete_all
  # What the person said "Always" to (Permission).
  has_many :permissions, -> { order(:tool_name, :recipient) }, dependent: :delete_all

  validates :name, :instructions, presence: true
  validates :name, length: { maximum: 200 }
  # The part of its email address before @ the install's domain; one domain
  # serves every person, so it is unique across the install.
  validates :email_name, format: { with: /\A[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?\z/, message: "may have only lowercase letters, digits, dots, dashes and underscores" },
    uniqueness: true
  before_validation :name_email, on: :create
  validates :model, inclusion: { in: ->(_) { models } }
  validates :thinking_level, inclusion: { in: THINKING_LEVELS }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) + %w[ UTC ] }
  validate :tools_are_catalogued, :capabilities_are_allowed
  validate :tools_fit

  # Its thread exists from the start; the sidecar admits it when first used (Conversation#admit!).
  after_create { conversations.create!(user: user, request_id: "thread") }
  # The header and the sidebar follow a new name, however it was set.
  after_update_commit -> { conversation&.broadcast_title }, if: :saved_change_to_name?
  after_update -> { routines.each(&:replan) }, if: :saved_change_to_time_zone?
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
  # instructions.md. The created record is then the live agent. Its model is the
  # starter's when this environment offers it, since an install names the route
  # it pays for; otherwise the environment's default (development's stand-in).
  def self.starter(name)
    directory = Rails.root.join("config/agents", name.to_s)
    settings = YAML.safe_load_file(directory.join("agent.yml"))
    { name: settings.fetch("name"), tool_names: settings.fetch("tools"),
      model: settings["model"].presence_in(models) || DurableAssistants.config(:pi_durable, :default_model, default: settings["model"]),
      thinking_level: settings.fetch("thinking_level", "medium"), time_zone: settings.fetch("time_zone", "UTC"),
      capabilities: settings.fetch("capabilities"),
      instructions: directory.join("instructions.md").read.strip,
      computer_attributes: starter_computer(settings["computer"]) }.compact
  end

  # A starter may name the kind of computer its agents get, on; the
  # environment must offer that kind (config/pi_durable.yml), or they get none.
  def self.starter_computer(provider)
    { provider: provider, state: "on" } if Computer.providers.include?(provider)
  end

  accepts_nested_attributes_for :computer

  # The tool classes this agent may call, the concourse_ tools when it is on
  # Concourse, then the tools of the connectors a conversation uses
  # (Conversation#connectors). A stored name with no class is refused by
  # validation, and by the ledger if it slipped past. Two outside names that
  # read the same after sanitising keep the first: the sidecar refuses a
  # definition that repeats one. A connector that isn't loaded adds none of
  # its tools; find_tools and use_tool reach them instead, and a tool the
  # agent called through use_tool (activated, most recent last) is declared
  # as itself from the next message, as pi's deferred exposure does, while
  # there is room: the least recently used go first. use_tool then no longer
  # offers it, so the agent calls it directly. They are declared in name
  # order, so using one changes nothing the sidecar sees. A tool the person
  # turned off, for this agent (disabled_tools) or on its connector for every
  # agent (McpServer#tool_classes), is in neither list. Nor is a tool of a
  # connector that needs the person to sign in (McpServer#needs_sign_in?):
  # a call could only fail, and signing in brings them back. The limit still
  # counts them (signed_out: true), so signing in never takes an agent past it.
  def tools(connectors, activated: [], signed_out: false)
    connectors = connectors.reject(&:needs_sign_in?) unless signed_out
    own = built_in_tools + Tool::Catalog::ALWAYS
    own << Tool::ReadSkill if skills.any?
    own.concat(Tool::Catalog::CONCOURSE) if concourse_agent && DurableAssistants::Concourse.configured?
    own.concat(Tool::Catalog::EMAIL) if DurableAssistants::Email.configured?
    own.concat(Tool::Catalog::CAMPFIRE) if campfire_bot && CampfireBot.configured?
    own.concat(Tool::Catalog::SAVED_SIGN_INS) if computer&.on? && computer.sprites? && DurableAssistants::Passbolt.configured?
    loaded, searched = connectors.partition(&:loaded?)
    searched = searched.flat_map(&:tool_classes).reject { tool_off?(it.tool_name) }
    tools = (own + loaded.flat_map(&:tool_classes)).reject { tool_off?(it.tool_name) }.uniq(&:tool_name)
    return tools if searched.empty?
    found = activated.reverse.filter_map { |name| searched.find { it.tool_name == name } }
    found = found.first([ TOOL_LIMIT - tools.size - 2, 0 ].max).sort_by(&:tool_name)
    declared = found.map(&:tool_name)
    tools + [ Tool::FindTools.new(searched, declared: declared), Tool::UseTool.new(searched, declared: declared) ] + found
  end

  # The catalogue's tools the person picked for it (tool_names).
  def built_in_tools = tool_names.filter_map { Tool::Catalog.find(it) }

  def tool_off?(name) = disabled_tools.include?(name)

  # How many tools its thread declares, as its settings' meter counts them:
  # Agent#tools for the thread's connectors, find_tools and use_tool
  # included, and no tool the agent looked up, which only ever fills spare room.
  def tool_count = tools(conversation ? conversation.connectors : user.mcp_servers.global.select(&:enabled?)).size

  # A tool switched on or off for this agent alone, from its settings: one of
  # the catalogue's in tool_names (as before), an ability in capabilities, and
  # any other, a connector's included, in disabled_tools.
  def switch_tool(name, on)
    column = if Tool::Catalog.names.include?(name) then :tool_names
    elsif Agent.capability_names.include?(name) then :capabilities
    end
    if column
      update(column => on ? (public_send(column) | [ name ]) : public_send(column) - [ name ])
    else
      update(disabled_tools: on ? disabled_tools - [ name ] : disabled_tools | [ name ])
    end
  end

  # Everything the sidecar runs a conversation of this agent on, named by its own
  # digest, so the sidecar installs each definition once and never caches a
  # stale one. The tools are a conversation's (Conversation#definition).
  def definition(tools)
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

  # Its address where the install has email (docs/email.md).
  def email_address = ("#{email_name}@#{DurableAssistants::Email.domain}" if DurableAssistants::Email.configured?)

  def to_s = name


  # Whether the person said "Always" to a call like this one: to every call of
  # its tool, or to each recipient it reaches. A call that reaches one more
  # recipient than they allowed asks again.
  def allows_always?(tool)
    return false unless tool.always?
    granted = permissions.where(tool_name: tool.permission_name).pluck(:recipient)
    granted.include?("") || (tool.recipients.any? && (tool.recipients - granted).empty?)
  end

  private
    def name_email
      return if email_name.present?
      base = name.to_s.parameterize.first(40).delete_suffix("-").presence || "agent"
      self.email_name = (1..).lazy.map { it == 1 ? base : "#{base}-#{it}" }.find { !Agent.exists?(email_name: it) } # tenancy-ok: addresses are unique across the install
    end

    def tools_are_catalogued
      (Array(tool_names) - Tool::Catalog.names).each { errors.add(:tool_names, "includes #{it}, which is not a tool") }
    end

    def capabilities_are_allowed
      errors.add(:capabilities, "repeat one") if Array(capabilities).uniq.size != Array(capabilities).size
      (Array(capabilities) - Agent.capability_names).each { errors.add(:capabilities, "include #{it}, which is not available") }
    end

    # Each conversation may use its own connectors, so each must fit; one not
    # made yet has the person's.
    def tools_fit
      sets = conversations.map(&:connectors).presence || [ user.mcp_servers.global.where(enabled: true).to_a ]
      count = sets.map { tools(it, signed_out: true).size }.max
      errors.add(:tool_names, "come to #{count}; an agent can have #{TOOL_LIMIT}") if count > TOOL_LIMIT
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
