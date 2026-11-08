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
  # Its own Passbolt user's key, entered by whoever made that user, so what it
  # saves and reads in the vault is its own (DurableAssistants::Passbolt).
  encrypts :passbolt_private_key, :passbolt_passphrase
  has_many :revisions, dependent: :delete_all
  # An agent is one thread (CONTEXT.md): `conversation` is it. Any others are
  # branches made before they were dropped, kept for the installs that have them.
  has_many :conversations, dependent: :destroy
  has_one :conversation, -> { where(parent_id: nil) }, inverse_of: :agent
  has_many :notes, dependent: :delete_all
  # Its canvas: what it and the person write beside the thread.
  has_many :documents, dependent: :destroy
  has_many :routines, dependent: :delete_all
  has_one :campfire_bot, dependent: :destroy
  has_one :computer, dependent: :destroy
  # Its identity on Concourse, when it has one.
  has_one :concourse_agent, dependent: :destroy
  has_many :peer_tasks, through: :conversations
  has_many :invocations, through: :conversations
  has_many :skills, -> { order(:name) }, dependent: :delete_all
  has_many :prompts, -> { order(:name) }, dependent: :delete_all
  # What the person said "Always" to (Permission).
  has_many :permissions, -> { order(:tool_name, :recipient) }, dependent: :delete_all

  # Who it is to everyone it writes to: given when it is made, never changed
  # (an address that changed would strand every thread it is in).
  attr_readonly :name, :email_name

  validates :name, :instructions, presence: true
  validates :name, length: { maximum: 200 }
  # What it does, beside its name wherever it is listed ("Chief of Staff").
  # Unlike the name, it may change.
  TITLE_LIMIT = 60
  normalizes :title, with: -> { it.squish.presence }
  validates :title, length: { maximum: TITLE_LIMIT }
  # The part of its email address before @ the install's domain; one domain
  # serves every person, so it is unique across the install.
  EMAIL_NAME = /\A[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?\z/
  validates :email_name, format: { with: EMAIL_NAME, message: "may have only lowercase letters, digits, dots, dashes and underscores" },
    uniqueness: { message: "is another agent's" }
  # The person may choose it at New agent, as they type it: "Jordan@" is jordan@.
  normalizes :email_name, with: -> { it.strip.downcase.delete_suffix("@").presence }
  before_validation :name_email, on: :create
  # Its own number for texts, one of the install's voip.ms numbers, set by its
  # person (docs/phone.md): ten digits, as voip.ms takes it. Two agents can't
  # share one, since a number's texts come from one agent.
  PHONE_NUMBER = /\A[2-9]\d{2}[2-9]\d{6}\z/
  normalizes :phone_number, with: -> { it.gsub(/\D/, "").sub(/\A1(?=\d{10}\z)/, "").presence }
  validates :phone_number, format: { with: PHONE_NUMBER, message: "should be a ten-digit North American number" },
    uniqueness: { message: "is another agent's" }, allow_nil: true
  validates :model, inclusion: { in: ->(_) { models } }
  validates :thinking_level, inclusion: { in: THINKING_LEVELS }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) + %w[ UTC ] }
  validate :tools_are_catalogued, :capabilities_are_allowed
  validate :tools_fit

  # Its thread exists from the start; the sidecar admits it when first used (Conversation#admit!).
  after_create { conversations.create!(user: user, request_id: "thread") }
  # Where the install can sign in to Campfire, every new agent is a bot there too (docs/campfire.md).
  after_create_commit -> { CampfireBotJob.perform_later(self) }, if: -> { DurableAssistants::Campfire.admin? }
  # Read before the conversations go; deleted after the agent is.
  before_destroy :remember_sprites, prepend: true
  after_destroy_commit :remove_sprites
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

  # The part before @ that an agent of this name gets: its name made into an
  # address, numbered past any taken. New agent shows it as the name is typed.
  def self.email_name_for(name)
    base = email_base(name)
    (1..).lazy.map { it == 1 ? base : "#{base}-#{it}" }.find { !Agent.exists?(email_name: it) } # tenancy-ok: addresses are unique across the install
  end

  def self.email_base(name) = name.to_s.parameterize.first(40).delete_suffix("-").presence || "agent"

  # Whether an agent somewhere in the install already goes by this name or the
  # address it would make.
  def self.taken?(name)
    exists?(name: name) || exists?(email_name: email_base(name)) # tenancy-ok: names and addresses are seen across the install
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
    own = built_in_tools + Tool::Catalog::ALWAYS + Tool::Catalog::CANVAS
    own << Tool::ReadSkill if skills.any?
    own.concat(Tool::Catalog::CONCOURSE) if concourse_agent&.admitted? && DurableAssistants::Concourse.configured?
    own.concat(Tool::Catalog::EMAIL) if DurableAssistants::Email.configured?
    own.concat(Tool::Catalog::CAMPFIRE) if campfire_bot && CampfireBot.configured?
    own.concat(Tool::Catalog::PHONE) if texts?
    own.concat(Tool::Catalog::SAVED_SIGN_INS) if computer&.on? && computer.sprites? && DurableAssistants::Passbolt.configured?(self)
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
    body = { instructions: identity + instructions + skills_listing, model: model, thinkingLevel: thinking_level, tools: tools.map(&:declaration),
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

  # Who it is, from the app, above the instructions it may rewrite: its name
  # and address are fixed when it is made, so the instructions can't drift
  # from them unseen. The title, which may change, is a paragraph of its own:
  # the sidecar sends a change to the first as a new prompt, at the cost of
  # the prompt cache (agent/current-instructions.mjs), and the rest as updates.
  def identity
    "Your name is #{name}#{" and your email address is #{email_address}" if email_address}. Neither can be changed.\n\n" +
      (title ? "Your title is #{title}.\n\n" : "") +
      (texts? ? "Your phone number is #{phone_label}; you text from it with send_text.\n\n" : "")
  end

  # It sends texts with a number of its own where the install has voip.ms.
  def texts? = phone_number.present? && DurableAssistants::Voipms.configured?

  # Its number as people write it: (647) 555-0123.
  def phone_label = (phone_number && "(#{phone_number[0, 3]}) #{phone_number[3, 3]}-#{phone_number[6, 4]}")

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
    def remember_sprites
      @sprites = ([ computer.name, conversations.pluck(:durable_id).compact ] if computer&.sprites?)
    end

    def remove_sprites
      ComputerRemovalJob.perform_later(user, id, *@sprites) if @sprites&.last.present?
    end

    def name_email
      self.email_name = Agent.email_name_for(name) if email_name.blank?
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
