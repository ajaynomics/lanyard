class Agent < ApplicationRecord
  include Pausable
  include LinkedCalendar
  include SendingHours
  include Movable, Reporting

  # Old workers still read this during a rolling deploy.
  self.ignored_columns += %w[ asks_every_instruction_change promotes_found_tools ]

  # Every level pi-ai knows, in order, as people read them. Which of them a
  # model supports is pi-ai's fact (ModelCatalog); the sidecar runs a model at
  # its nearest supported level, so a level is never a reason to refuse an agent.
  THINKING_LEVEL_NAMES = { "off" => "Off", "minimal" => "Minimal", "low" => "Low", "medium" => "Medium",
                           "high" => "High", "xhigh" => "Extra high", "max" => "Maximum" }.freeze
  THINKING_LEVELS = THINKING_LEVEL_NAMES.keys.freeze
  TOOL_LIMIT = 59 # leave five of the sidecar's 64 places free for tool_search to fill
  SIDECAR_TOOLS = JSON.parse(Rails.root.join("agent/own-tools.json").read).freeze
  LOOKUP_LIMIT = 1024 # the most lookup tools it takes beside them (agent/runtime.mjs)
  TOOL_WARNING = 56 # where its settings start saying what to turn off
  # The sidecar's built-in abilities, as the agent's settings describe them. Not
  # tools: Rails has no code for them, it only says whether the agent has them.
  CAPABILITY_DESCRIPTIONS = {
    "codemode" => [ "Code", "Writes and runs short scripts that call several tools at once." ],
    "subagents" => [ "Helpers", "Hands a self-contained piece of work to a helper that reports back." ],
    "web_search" => [ "Web search", "Searches the web and cites its sources." ]
  }.freeze

  belongs_to :user
  # Its workspace, for life. People reach it through the workspace; `user` is
  # only who made it.
  belongs_to :workspace
  # The agent that now takes this one's mail, set when it replaced this one
  # (docs/email.md). One step only: neither end may forward further.
  belongs_to :mail_to_agent, class_name: "Agent", optional: true
  has_many :mail_from_agents, class_name: "Agent", foreign_key: :mail_to_agent_id, inverse_of: :mail_to_agent
  # Its own Passbolt user's key, entered by whoever made that user, so what it
  # saves and reads in the vault is its own (DurableAssistants::Passbolt).
  encrypts :passbolt_private_key, :passbolt_passphrase, :caldav_password
  has_many :revisions, dependent: :delete_all
  # An agent is one thread (CONTEXT.md): `conversation` is it. Any others are
  # branches made before they were dropped, kept for the installs that have them.
  has_many :conversations, dependent: :destroy
  has_one :conversation, -> { where(parent_id: nil) }, inverse_of: :agent
  has_one :workspace_setup, class_name: "Workspace::AgentSetup", inverse_of: :agent
  has_many :notes, dependent: :delete_all
  # Its canvas: what it and the person write beside the thread.
  # Its canvas; a deleted document waits apart until it is restored or purged (Document::Deletable).
  has_many :documents, -> { kept }, dependent: :destroy, inverse_of: :agent
  has_many :deleted_documents, -> { deleted }, class_name: "Document", dependent: :destroy, inverse_of: :agent
  has_many :routines, dependent: :delete_all
  has_one :campfire_bot, dependent: :destroy
  # Its Telegram bot, which only the workspace's owner sets (TelegramBot).
  has_one :telegram_bot, dependent: :destroy
  has_one :computer, dependent: :destroy
  has_many :pilot_budgets, class_name: "Agent::PilotBudget", dependent: :delete_all
  has_many :voice_calls, class_name: "Agent::VoiceCall"
  # Its mail accounts and calendar servers, which only the workspace's owner
  # sets (Agent::MailAccount, Agent::CalendarServer): its own, which it sends
  # and writes through, and any it only reads, such as a colleague's whose work
  # it took over. `mail_account` and `calendar_server` are always its own.
  has_many :mail_accounts, class_name: "Agent::MailAccount", dependent: :destroy
  has_one :mail_account, -> { where(read_only: false, only_when_named: false) }, class_name: "Agent::MailAccount", inverse_of: :agent, dependent: :destroy
  has_many :named_mail_accounts, -> { where(read_only: false, only_when_named: true).order(:id) }, class_name: "Agent::MailAccount", inverse_of: :agent
  has_one :gmail_inbox, class_name: "Agent::GmailInbox", inverse_of: :agent, dependent: :destroy
  has_many :calendar_servers, class_name: "Agent::CalendarServer", dependent: :destroy
  has_one :calendar_server, -> { where(read_only: false) }, class_name: "Agent::CalendarServer", inverse_of: :agent, dependent: :destroy
  # Its identities on Concourse, one in each organization (network) it joined,
  # oldest first.
  has_many :concourse_agents, -> { order(:id) }, dependent: :destroy, inverse_of: :agent
  has_many :peer_tasks, through: :conversations
  has_many :invocations, through: :conversations
  has_many :dispatches, through: :invocations
  has_many :helpers, through: :conversations
  has_many :workflow_runs, through: :conversations
  # Another tab or device on its settings, or its page, morphs to match
  # (layouts/settings); so does each of its parts (Note, Skill, Routine...).
  broadcasts_refreshes

  has_many :skills, -> { order(:name) }, dependent: :delete_all
  has_many :prompts, -> { order(:name) }, dependent: :delete_all
  # What the person said "Always" to (Permission).
  has_many :permissions, -> { order(:tool_name, :recipient) }, dependent: :delete_all
  # The person's connectors that are core for it; every other one is lookup.
  has_many :core_connectors, class_name: "Agent::CoreConnector", dependent: :delete_all
  # Connectors that stopped being core for it on their own (McpServer#refresh).
  has_many :connector_moves, class_name: "Agent::ConnectorMove", dependent: :delete_all

  validates :name, :instructions, presence: true
  normalizes :name, with: -> { it.squish }
  validates :name, uniqueness: { scope: :workspace_id, case_sensitive: false, message: "is another agent's" },
    on: :update, if: :will_save_change_to_name?
  # The app puts the identity (below) above the instructions. An agent asked
  # to start from its current ones copies it in, and would then read it twice,
  # one copy going stale when a title or number changes. So any run of identity
  # paragraphs at the very start is dropped; a person's own words further on
  # are never touched.
  IDENTITY_HEADER = /\A\s*(?:(?:Your name is [^\n]+\. Neither can be changed\.|Your title is [^\n]+\.|Your phone number is [^\n]+; you text from it with send_text\.|On Concourse you are in these networks, [^\n]+)[ \t]*(?:\n\s*|\z))+/
  normalizes :instructions, with: -> { it.sub(IDENTITY_HEADER, "") }
  validates :name, length: { maximum: 200 }
  # What it does, beside its name wherever it is listed ("Chief of Staff").
  # Unlike the name, it may change.
  TITLE_LIMIT = 60
  normalizes :title, with: -> { it.squish.presence }
  validates :title, length: { maximum: TITLE_LIMIT }
  # The part of its email address before @ its workspace's domain or the
  # install's. Unique across the install, so an address names one agent
  # whichever domain it is at (AgentsMailbox).
  EMAIL_NAME = /\A[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?\z/
  validates :email_name, format: { with: EMAIL_NAME, message: "may have only lowercase letters, digits, dots, dashes and underscores" },
    uniqueness: { message: "is another agent's" }
  # One it left stays its own, so its mail reaches no other; it may go back.
  validate(if: :will_save_change_to_email_name?) { errors.add(:email_name, "was another agent's") if Agent.where.not(id: id).once_at(email_name).exists? } # tenancy-ok: addresses are unique across the install
  before_update :leave_email_name, if: :will_save_change_to_email_name?
  scope :once_at, ->(email_name) { where("EXISTS (SELECT 1 FROM json_each(agents.former_email_names) WHERE value = ?)", email_name) }
  # The person may choose it at New agent, as they type it: "Jordan@" is jordan@.
  normalizes :email_name, with: -> { it.strip.downcase.delete_suffix("@").presence }
  before_validation :name_email, on: :create
  # Its workspace's owner may change it (Agents::EmailAddressesController).
  # The new address is its only one; replies in a thread it started from the
  # old one still reach it, by the thread (AgentsMailbox). Not while its
  # computer is install-managed SSH, whose folder is named after it
  # (Computer::ConfiguredSsh): the agent would lose its files.
  validate :keeps_computer_folder, on: :update, if: :will_save_change_to_email_name?
  # Its own number for texts, one of the install's voip.ms numbers, set by its
  # person (docs/phone.md): ten digits, as voip.ms takes it. Two agents can't
  # share one, since a number's texts come from one agent.
  NOTES_LISTED = 50
  PHONE_NUMBER = /\A[2-9]\d{2}[2-9]\d{6}\z/
  normalizes :caldav_username, :caldav_password, with: -> { it.strip.presence }
  normalizes :phone_number, with: -> { it.gsub(/\D/, "").sub(/\A1(?=\d{10}\z)/, "").presence }
  validates :phone_number, format: { with: PHONE_NUMBER, message: "should be a ten-digit North American number" },
    uniqueness: { message: "is another agent's" }, allow_nil: true
  # A model no longer allowed is kept by an agent that has it, and runs as before; it can't be chosen anew.
  validates :model, inclusion: { in: ->(_) { models } }, unless: -> { persisted? && !will_save_change_to_model? }
  validates :thinking_level, inclusion: { in: THINKING_LEVELS }
  # Its own Claude route, first before the install's order (docs/agent.md,
  # "Claude routes"); none is the install's order. One the install has since
  # dropped is kept, and the sidecar goes by the install's order instead.
  normalizes :claude_route, with: -> { it.presence }
  validates :claude_route, inclusion: { in: ->(_) { claude_routes } }, allow_nil: true, if: :will_save_change_to_claude_route?
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) + %w[ UTC ] }
  validate :tools_are_catalogued, :capabilities_are_allowed
  validate :mail_goes_one_step, if: :mail_to_agent
  # A name the install lists in APP__OWNER_APPROVAL_AGENTS is never given to a
  # new agent: the listed agent would approve everything (Agent#approvals), so
  # a deleted one's name must not pass to someone else's.
  validate :email_name_not_reserved, on: :create

  # Its thread exists from the start; the sidecar admits it when first used (Conversation#admit!).
  after_create { conversations.create!(request_id: "thread") }
  after_create :carry_office_connectors
  # A delegated setup approves one local agent, not an external Campfire bot.
  after_create_commit -> { CampfireBotJob.perform_later(self) }, if: -> { campfire.admin? && !workspace_setup }
  # Read before the conversations go; deleted after the agent is.
  before_destroy :remember_sprites, prepend: true
  after_destroy_commit :remove_sprites
  after_update -> { routines.each(&:replan) }, if: :saved_change_to_time_zone?
  after_update_commit -> { conversation&.broadcast_status_line }, if: -> { saved_change_to_model? || saved_change_to_thinking_level? }
  after_update_commit -> { conversation&.broadcast_row }, if: -> { saved_change_to_title? || saved_change_to_name? }
  after_update_commit -> { campfire_bot&.rename }, if: :saved_change_to_name?
  after_save :record_revision, if: -> { saved_change_to_instructions? || saved_change_to_model? || saved_change_to_tool_names? || saved_change_to_capabilities? }

  # The model routes the sidecar will run, per environment (config/pi_durable.yml).
  def self.models
    DurableAssistants.config(:pi_durable, :models, default: [])
  end

  # The install's Claude routes by name, in its order (config/pi_durable.yml).
  def self.claude_routes
    DurableAssistants.config(:pi_durable, :claude_routes, default: []).map(&:to_s)
  end

  # The capabilities an agent may have here (config/pi_durable.yml).
  def self.capability_names
    DurableAssistants.config(:pi_durable, :capabilities, default: [])
  end

  # The part before @ that an agent of this name gets: its name made into an
  # address, numbered past any taken. New agent shows it as the name is typed.
  def self.email_name_for(name)
    base = email_base(name)
    (1..).lazy.map { it == 1 ? base : "#{base}-#{it}" }.find { !email_name_taken?(it) && !it.in?(owner_approval_names) } # tenancy-ok: addresses are unique across the install
  end

  def self.email_name_taken?(email_name) = exists?(email_name: email_name) || once_at(email_name).exists? # tenancy-ok: addresses are unique across the install

  def self.email_base(name) = name.to_s.parameterize.first(40).delete_suffix("-").presence || "agent"

  # Whether an agent somewhere in the install already goes by this name or the
  # address it would make.
  def self.taken?(name)
    exists?(name: name) || email_name_taken?(email_base(name)) # tenancy-ok: names and addresses are seen across the install
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
      capabilities: starter_capabilities(settings.fetch("capabilities")),
      instructions: directory.join("instructions.md").read.strip,
      computer_attributes: starter_computer(settings["computer"]) }.compact
  end

  # A starter may name the kind of computer its agents get, on; the
  # environment must offer that kind (config/pi_durable.yml), or they get none.
  def self.starter_computer(provider)
    { provider: provider, state: "on" } if Computer.providers.include?(provider)
  end

  # Code mode is how an agent reaches its looked-up connectors' tools in one
  # script, so every new agent has it where the install offers it, whatever
  # its starter lists.
  def self.starter_capabilities(listed) = listed | (capability_names & %w[ codemode ])

  accepts_nested_attributes_for :computer

  # The tool classes this agent may call, the concourse_ tools when it is on
  # Concourse, then the tools of the connectors a conversation uses
  # (Conversation#connectors). A stored name with no class is refused by
  # validation, and by the ledger if it slipped past. Two outside names that
  # read the same after sanitising keep the first: the sidecar refuses a
  # definition that repeats one. Of its built-ins only the core (Tool::Catalog::CORE)
  # are declared; the rest are lookup, as a connector is unless core for this
  # agent (#core?): the model finds them with the sidecar's tool_search and
  # calls them by name, and so does a code mode script, as tools.<name>
  # (#lookup_tools). A tool turned off for this
  # agent, its workspace, its install, or on its connector (McpServer#tool_classes)
  # is in neither list. Nor is a tool of a connector that needs the person to
  # sign in (McpServer#needs_sign_in?): a call could
  # only fail, and signing in brings them back. The limit still counts them
  # (signed_out: true), so signing in never takes an agent past it.
  #
  # Two or more Google connectors of one kind give one set of its tools, with
  # an account argument (Tool::Mcp::Group). The model sees the sidecar's own
  # tools beside them. The declaration leaves room for tools found later:
  # past TOOL_LIMIT, the last core connectors' tools are looked up instead,
  # always the same ones. The agent's meter shows what it wants, including
  # this overflow (#wanted_tool_count).
  def tools(connectors, signed_out: false) = toolset(connectors, signed_out:).first

  def pilot_budget(kind)
    pilot_budgets.find_or_create_by!(kind: kind, month: PilotBudget.month_at(Time.current))
  end

  # What it declares, and the lookup tools it finds with tool_search and calls
  # beside them. tool_search is the sidecar's own beside lookup tools, so it
  # takes a place of the declared ones whenever there are any.
  def toolset(connectors, signed_out: false)
    tools, lookup = wanted_tools(connectors, signed_out:)
    limit = declared_tool_limit
    finding = lookup_sidecar_tool_names.size
    return [ tools, lookup ] if tools.size + (lookup.any? ? finding : 0) <= limit
    [ tools.first(limit - finding), tools.drop(limit - finding) + lookup ]
  end

  # How many tools the model would see were there no limit, the sidecar's own
  # among them: what its settings' meter and a connector's save count. `core`
  # stands for the connectors core for it, to ask what one more would do.
  def wanted_tool_count(connectors, signed_out: false, core: core_server_ids)
    tools, lookup = wanted_tools(connectors, signed_out:, core:)
    tools.size + (lookup.any? ? lookup_sidecar_tool_names.size : 0) + sidecar_tool_names.size
  end

  # The tools the sidecar adds beside those Rails declares, by ability and
  # computer, from its own list (agent/own-tools.json). A computer that keeps
  # its browser counts its desktop, though a conversation the sidecar has not
  # started yet has none: the most it could add.
  def sidecar_tool_names
    names = capabilities.flat_map { SIDECAR_TOOLS.dig("capabilities", it) || [] }
    return names unless computer&.on?
    names + SIDECAR_TOOLS["computer"] + (computer.sprites? ? SIDECAR_TOOLS["sprites"] : []) +
      (computer.retains_browser? ? SIDECAR_TOOLS["retainedBrowser"] : [])
  end

  def declared_tool_limit = TOOL_LIMIT - sidecar_tool_names.size

  # tool_search, which the sidecar offers beside the lookup tools (#definition,
  # agent/own-tools.json): what the model sees to reach them.
  def lookup_sidecar_tool_names = SIDECAR_TOOLS["lookup"]

  def default_connectors = conversation ? conversation.connectors : workspace.mcp_servers.global.select(&:enabled?)

  # The tools before the limit: those declared, and those looked up. Its rarer
  # built-ins are looked up ahead of its connectors' tools.
  def wanted_tools(connectors, signed_out: false, core: core_server_ids)
    connectors = connectors.reject(&:needs_sign_in?) unless signed_out
    carried, rare = own_tools.partition { Tool::Catalog.core?(it) }
    sets = connectors.group_by { it.google ? [ :google, it.google ] : it }.values
    loaded, searched = sets.partition { |set| set.any? { core?(it, core) } }
    declared = (carried + loaded.flat_map { set_tools(it) }).uniq(&:tool_name)
    # Two names that read the same after sanitising (get-page, get_page) keep
    # the first, as declared ones do: the sidecar refuses a definition whose
    # lookup repeats a name, or names a declared tool, and then every message.
    names = declared.map(&:tool_name).to_set
    [ declared, (rare + searched.flat_map { set_tools(it) }).uniq(&:tool_name).reject { names.include?(it.tool_name) } ]
  end

  # Every built-in tool it has, declared or looked up, and not switched off.
  def own_tools = available_own_tools.reject { tool_off?(it.tool_name) }

  # Settings must still show a tool that a higher level has turned off.
  def available_own_tools
    own = built_in_tools + Tool::Catalog::ALWAYS + Tool::Catalog::CANVAS
    # A workflow's every step is a helper; the agent checks on and cancels its own.
    own.push(Tool::RunWorkflow, Tool::CheckHelper, Tool::CancelHelper) if capabilities.include?("subagents")
    own << Tool::ReadSkill if skills.ready.any?
    own.concat(Tool::Catalog::CARDS)
    own.concat(Tool::Catalog::QUESTIONS) if own.include?(Tool::AskPerson)
    own.concat(Tool::Catalog::CONCOURSE) if concourse_networks.any? && DurableAssistants::Concourse.configured?
    own.concat(Tool::Catalog::EMAIL) if sends_email?
    own.concat(Tool::Catalog::DRAFTS) if mail_account&.saves_drafts?
    own.concat(Tool::Catalog::CAMPFIRE) if campfire_bot && campfire.configured?
    own.concat(Tool::Catalog::PHONE) if texts?
    own.concat(Tool::Catalog::VOICE.select { it.available_to?(self) })
    own.concat(Tool::Catalog::TELEGRAM) if telegram_bot&.usable?
    own.concat(Tool::Catalog::CALENDAR) if calendar?
    own.concat(saved_sign_ins) if screen? && DurableAssistants::Passbolt.configured?(self)
    # What goes to the screen's browser is for an agent with a screen alone,
    # and a card only for its computer's: its own browser on the host takes no card.
    own.uniq(&:tool_name).select { (!it.on_screen? || screen?) && (!it.pays? || computer&.screen?) }
  end

  # Whether a connector's tools are in every message it reads (core), or found
  # when needed (lookup). A person's connector is core for the agents it was
  # made core for (Agent::CoreConnector); a conversation's own says so itself.
  def core?(server, ids = core_server_ids) = server.conversation_id ? server.loaded? : ids.include?(server.id)

  # Read afresh: a connector made core elsewhere counts at once.
  def core_server_ids = new_record? ? [] : core_connectors.pluck(:mcp_server_id)

  # How many tools it would want were the connector core for it too: in each
  # of its conversations: what pinning one more must fit (Agent::CoreConnector).
  def tool_count_with_core(server)
    sets = conversations.map(&:connectors).presence || [ workspace.mcp_servers.global.where(enabled: true).to_a ]
    sets.map { wanted_tool_count(it, signed_out: true, core: core_server_ids | [ server.id ]) }.max
  end

  def codemode? = capabilities.include?("codemode")

  # A connector's tools, or one Google kind's across its connectors.
  def set_tools(set)
    on = ->(server) { server.tool_classes.reject { tool_off?(it.tool_name) } }
    return on.(set.sole) if set.one?
    servers = set.sort_by(&:name)
    servers.flat_map(&on).group_by { it.listing["name"] }.map { |_, members| Tool::Mcp::Group.new(servers.first.google, servers, members) }
      .reject { tool_off?(it.tool_name) }
  end

  # The catalogue's tools the person picked for it (tool_names).
  def built_in_tools = tool_names.filter_map { Tool::Catalog.find(it) }.select { it.available_to?(self) }

  def tool_off?(name) = disabled_tools.include?(name) || workspace.tool_off?(name)

  def asks_every_send?(name)
    flag = Tool::AsksEverySend::TOOL_SETTINGS[name]&.first
    flag && (public_send(flag) || workspace.asks_every?(Tool::AsksEverySend::REPLY_SETTING.fetch(name, name)))
  end

  def asks_own_instruction_change?
    own_instruction_approval.nil? ? workspace.asks_own_instruction_change? : own_instruction_approval
  end

  # How many tools its thread declares, as its settings' meter counts them:
  # Agent#tools for the thread's connectors, and no tool the agent looked up,
  # which only ever fills spare room.
  def tool_count = wanted_tool_count(default_connectors)

  # A tool switched on or off for this agent alone, from its settings: one of
  # the catalogue's in tool_names (as before), an ability in capabilities, and
  # any other, a connector's included, in disabled_tools.
  def switch_tool(name, on)
    column = if Tool::Catalog.names.include?(name) then :tool_names
    elsif Agent.capability_names.include?(name) then :capabilities
    else :disabled_tools
    end

    if column != :capabilities && (source = workspace.tool_off_source(name))
      errors.add(:base, "#{name.humanize} is turned off for this agent: set for #{source}.")
      return false
    end

    names = public_send(column)
    update(column => (on == (column == :disabled_tools) ? names - [ name ] : names | [ name ]))
  end

  # Everything the sidecar runs a conversation of this agent on, named by its own
  # digest, so the sidecar installs each definition once and never caches a
  # stale one. The tools are a conversation's (Conversation#definition).
  # `lookup` carries the tools it looks up, which the model loads with the
  # sidecar's tool_search and a script finds with searchTools(), each calling
  # one by its name (agent/extensions.mjs); with none, the key is left out,
  # so the digest is as it was. Its workspace's
  # shared instructions follow its own, so a change to them reaches every
  # agent of that workspace on its next message. With helpers, `helperModels`
  # names the models they may run on (ModelCatalog.for_helpers); without, or
  # for a sidecar from before them, the key is left out likewise.
  def definition(tools, lookup: [], helper_models: capabilities.include?("subagents"), retained_browser: false)
    prompt = identity + instructions + workspace.instructions_prompt + reporting_instructions +
      skills_listing + lookup_note + notes_listing
    body = { instructions: prompt, model: model, thinkingLevel: thinking_level,
             tools: tools.map(&:declaration), capabilities: capabilities, computer: computer&.descriptor }
    if retained_browser
      body[:computer] = body[:computer].merge(retainedBrowser: true)
    elsif sandbox_drive_browser
      body[:computer] = body[:computer].merge(sandboxBrowser: true)
    end
    # The sidecar adds tool_search iff this is sent; keep it within #toolset's `searched.any?` that counts tool_search.
    body[:lookup] = lookup.first(LOOKUP_LIMIT).map(&:declaration) if lookup.any?
    body[:claudeRoute] = claude_route if claude_route
    body[:helperModels] = ModelCatalog.for_helpers if helper_models
    if (named = computer&.named_computers)
      body[:namedComputers] = named
    end
    body.merge(digest: Agent::Canonical.digest(body))
  end

  # Its approval policy: its workspace's, or the install's where that chose
  # none (Workspace::ApprovalPolicy). An agent the install names in
  # APP__OWNER_APPROVAL_AGENTS, by email name, approves everything wherever it
  # is. Core never asks on its behalf; its instructions say when to ask its
  # owner by text or email.
  def approvals
    if email_name.in?(Agent.owner_approval_names)
      Workspace::ApprovalPolicy.new("everything")
    else
      workspace.approvals
    end
  end

  def self.owner_approval_names = DurableAssistants.config(:app, :owner_approval_agents, default: [])

  # Its route was dropped from the install since it was chosen.
  def claude_route_dropped? = claude_route.present? && !claude_route.in?(self.class.claude_routes)

  # What the person typed, as the model should read it: `/skill:name args`
  # becomes pi's skill block, `/prompt args` its saved prompt. Anything else,
  # a built-in or an unknown `/foo`, goes as typed, as in pi.
  def expand(text)
    command, arguments = text.to_s.match(%r{\A/(\S+)(?:\s+(.*))?\z}m)&.captures
    return text unless command
    if command.start_with?("skill:")
      skills.ready.find_by(name: command.delete_prefix("skill:"))&.invocation(arguments, computer: computer) || text
    else
      prompts.find_by(name: command)&.expand(arguments) || text
    end
  end

  def change_instructions(text, approval:, invocation: nil, restored_by: nil, restored_from: nil)
    @instruction_provenance = { approval: approval, invocation: invocation, instruction_workspace: (workspace if approval),
      restored_by: restored_by, restored_from: restored_from }
    update!(instructions: text)
  ensure
    @instruction_provenance = nil
  end

  # Kept on every change to what the agent is, its skills and prompts included.
  # History cannot be added later.
  def record_revision
    revisions.create!(instructions: instructions, model: model, tool_names: tool_names, capabilities: capabilities,
      skills: skills.reload.map(&:snapshot), prompts: prompts.reload.map(&:snapshot), **(@instruction_provenance || {}))
  end

  # The agent's directory for a local computer; each conversation gets its own
  # directory inside it. Stable for the agent's lifetime: the sidecar binds each
  # conversation to it at admission. "bot-" is the folder's name on disk from
  # before the rename; it is only an identifier now, and changing it would
  # strand every conversation's files.
  def workdir
    Rails.configuration.x.agent_computers.join("bot-#{id}").to_s
  end

  # Who it is, from the app, above the instructions it may rewrite: its name
  # and address are fixed when it is made, so the instructions can't drift
  # from them unseen. The title, which may change, is a paragraph of its own:
  # the sidecar sends a change to the first as a new prompt, at the cost of
  # the prompt cache (agent/current-instructions.mjs), and the rest as updates.
  def identity
    "Your name is #{name}#{" and your email address is #{own_address}" if own_address}. Neither can be changed.\n\n" +
      (title ? "Your title is #{title}.\n\n" : "") +
      (texts? ? "Your phone number is #{phone_label}; you text from it with send_text.\n\n" : "") +
      (concourse_networks.many? ? "#{CONCOURSE_NETWORKS_LINE} #{concourse_networks.map { "#{it.organization} as #{it.handle}" }.to_sentence}.\n\n" : "")
  end

  # Said only on two or more networks, where a new concourse_send must name one;
  # on one, the agent's words are as they were before networks.
  CONCOURSE_NETWORKS_LINE = "On Concourse you are in these networks, so name one when you send a new task:"

  # The first identity, which tasks from before networks belong to (PeerTask#channel).
  def concourse_agent = concourse_agents.first

  # The identities it can read and send with now, oldest first.
  def concourse_networks = concourse_agents.select(&:speaks?)

  # Its Concourse tasks on networks it is still in. A task from a network it
  # left can no longer be answered or followed, so it closes with it.
  def current_peer_tasks = peer_tasks.where(concourse_agent_id: [ nil, *concourse_agent_ids ])

  # It sends texts with a number of its own where its workspace or the install has voip.ms.
  def texts? = phone_number.present? && DurableAssistants::Voipms.configured?(voipms_account)

  # The voip.ms account its texts go through: its workspace's own, or the install's (nil).
  def voipms_account = workspace.voipms_account(as: self)

  # Its own account, on a server of its own its owner named
  # (Agent::CalendarServer) or else on the install's CalDAV server, and the
  # calendars linked from another account (Agent::LinkedCalendar): either
  # gives it the calendar tools, which see all as one set of lists
  # (docs/calendar.md). So do the lists of servers it only reads, beside them.
  def calendar? = own_calendar? || linked_calendar? || read_only_calendar_servers.any?
  def own_calendar? = own_calendar_server? || install_calendar?
  def own_calendar_server? = !!(calendar_server&.event_only? || calendar_server&.usable?)
  def alarm_calendar? = !calendar_server&.event_only? && own_calendar?
  def install_calendar? = caldav_username.present? && caldav_password.present? && DurableAssistants::Caldav.configured?
  def caldav = DurableAssistants::Caldav::Combined.new(own_caldav, linked_caldavs, read_only_calendar_servers.map(&:caldav))
  def read_only_calendar_servers = calendar_servers.select { it.read_only? && it.usable? }

  # Those the clock reads for an alarm (AlarmSweepJob). Whether the
  # account or the server is usable now is #own_calendar?.
  scope :with_own_calendar, -> {
    where.not(caldav_username: nil).where.not(caldav_password: nil)
      .or(where(id: Agent::CalendarServer.where(read_only: false).select(:agent_id))) # tenancy-ok: the clock reads every owner's agents
  }

  # Whether a file a tool finds can be saved on its computer: any computer
  # the sidecar is given, in its own folder there (agent/files.mjs).
  def saves_files? = computer&.descriptor.present?

  def own_caldav
    if own_calendar_server? then calendar_server.caldav
    elsif install_calendar? then DurableAssistants::Caldav.new(caldav_username, caldav_password)
    end
  end

  # Its number as people write it: (647) 555-0123.
  def phone_label = (phone_number && "(#{phone_number[0, 3]}) #{phone_number[3, 3]}-#{phone_number[6, 4]}")

  # Its address, at its workspace's own domain or the install's (docs/email.md).
  def email_address = ("#{email_name}@#{workspace.agents_mail_domain}" if workspace.agents_mail?)

  # It sends mail through the install's server, or through its own account
  # where it has one it can sign in to.
  def sends_email? = workspace.agents_mail? || own_mail?
  def own_mail? = !!mail_account&.usable?

  # Its own account is its only address, where its owner chose so: its
  # address here is neither said to it, sent from nor read for it
  # (Agent::MailAccount, primary).
  def mail_primary? = !!mail_account&.primary?

  # The address its calendar invitations come from and its guests answer:
  # its own account where it can send through it, else its address here,
  # as send_email chooses. Where its account is its only address (primary),
  # its address here is not read for it, so an unusable account means none.
  def invitation_address = own_mail? ? mail_account.address : (email_address unless mail_primary?)

  # Every address an event it organised may name: one written while its
  # account worked still takes answers after it falls back to its address here.
  def invitation_addresses = [ mail_account&.address, (email_address unless mail_primary?) ].compact.uniq

  # The addresses send_email may name to go from (#618): its own account's
  # where it can send through it, and its address here unless the account is
  # its only one, and any it sends from only when named (#630). Never a
  # mailbox it only reads.
  def sending_addresses
    [ (mail_account.address if own_mail?), *named_mail_accounts.select(&:usable?).map(&:address), (email_address unless mail_primary?) ].compact.uniq
  end

  # The address it goes by, as said to it and shown beside it.
  def own_address = mail_primary? ? mail_account.address : email_address

  # Its settings that only the owner of its workspace sees and changes, such
  # as its own mail account: another member uses the agent but cannot point
  # its mail, or the copy of it, elsewhere.
  def owned_by?(person) = person.present? && workspace.owner == person

  # Its address stays while its computer is install-managed SSH, whose folder
  # is named after it (#keeps_computer_folder).
  def email_name_fixed? = !!computer&.configured_ssh?

  # Vault entries its own accounts sign in with: every mail account and
  # calendar server, those it only reads too, its linked calendar, its
  # Telegram bot's token, which as a key would send around every approval, and
  # its workspace's Campfire administrator, who could read every room, and the
  # OAuth app of any of its workspace's connectors (McpServer::Clio). Such a
  # password is for the app to use on the agent's behalf, never for the agent:
  # filled into the same host's webmail, a mailbox's would send around the
  # forced Bcc and every approval, or from a mailbox it may only read.
  # Matched by name as the vault finds one (Passbolt.find_by_name).
  def reserved_sign_in?(name)
    [ *mail_accounts.map(&:vault_entry), *calendar_servers.map(&:vault_entry), linked_calendar_entry, telegram_bot&.vault_entry,
      workspace.campfire_vault_entry, workspace.voipms_vault_entry, *workspace.mcp_servers.where.not(vault_entry: nil).pluck(:vault_entry) ].compact.any? { it.casecmp?(name.to_s) }
  end

  # Its own browser on the host, where the install maps one to it ("17=avery"):
  # a headless Chromium run as its sandbox user, where the sidecar fills a
  # saved sign-in (agent/fill-socket.mjs). The host's names have no dots.
  def sandbox_browser
    mappings = DurableAssistants.config(:pi_durable, :sandbox_browsers).to_s.split(",").filter_map { it.split("=", 2).map(&:strip) if it.include?("=") }
    mine = mappings.select { |agent_id, _| agent_id == id.to_s }
    name = mine.sole.last if mine.one?
    name if name.to_s.match?(/\A[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\z/) && mappings.count { |_, browser| browser == name } == 1
  end

  # The name is granted live, not stored in the sidecar definition or offered
  # as a tool argument. Only the agent's existing SSH identity can drive it.
  def sandbox_drive_browser
    sandbox_browser if computer && !computer.held? && computer.descriptor&.dig(:provider) == "ssh" && !computer.retains_browser?
  end

  # Its own browser on the host, for a fill, only where it has no desktop: with
  # one, visit_website and the desktop tool act on the desktop's browser, so
  # every fill goes to the tab visit_website opened there.
  def browser_without_desktop = (sandbox_browser unless computer&.screen?)

  # Whether it has a browser to sign in on: its computer's screen, or its own on the host.
  def screen? = computer&.screen? || sandbox_browser.present?

  # The Campfire its bot is on: its workspace's own, or the install's.
  def campfire = workspace.campfire(as: self)

  def to_s = name

  # An office connector the install says is core is core for it too, where it
  # fits: once made, and once moved to another workspace.
  def carry_office_connectors
    workspace.mcp_servers.global.select { it.install_entry&.dig(:loaded) == true }.each { it.make_core_for(self) }
  end


  # Whether a call that asks for approval runs without asking: its
  # workspace's approval policy allows it (its own, or the install's), or the
  # person answered "Always". A send switch takes priority over even an Always
  # for every recipient.
  def allows?(tool)
    return true if tool.always_with_recipients? && !tool.try(:asks_every_send?) && granted_every_recipient?(tool)
    return true if routine_unasked?(tool)
    return false if tool.even_approving_everything?
    return true if approvals.allows?(tool)
    # A policy that approves everything runs it; under any other, no stored
    # Always does, whatever the tool says of always?.
    return false if tool.every_time?
    allows_always?(tool)
  end

  # Wake timers in a workspace the install names (APP__ROUTINES_UNASKED_WORKSPACES)
  # are added and removed without a card, at its owner's word.
  def routine_unasked?(tool)
    tool.try(:sets_routines?) &&
      workspace_id.to_s.in?(DurableAssistants.config(:app, :routines_unasked_workspaces, default: []))
  end

  # Whether the person said "Always" to a call like this one: to every call of
  # its tool, or to each recipient it reaches. A call that reaches one more
  # recipient than they allowed asks again.
  def allows_always?(tool)
    return false unless tool.always?
    granted_recipients(tool).include?("") || granted_every_recipient?(tool)
  end

  def granted_every_recipient?(tool)
    tool.recipients.any? && (tool.recipients - granted_recipients(tool)).empty?
  end

  private
    def email_name_not_reserved
      errors.add(:email_name, "is kept for an agent the install names to approve everything") if email_name.in?(Agent.owner_approval_names)
    end

    def granted_recipients(tool) = permissions.where(tool_name: tool.permission_name).pluck(:recipient)

    # A retained browser, or its own on the host, gets what signing in on it
    # needs; the outside link needs no screen and stays with a Sprite's, as before.
    def saved_sign_ins = computer&.on? && computer.sprites? ? Tool::Catalog::SAVED_SIGN_INS : Tool::Catalog::SAVED_SIGN_INS - [ Tool::AskOutsideForSignIn ]

    def remember_sprites
      @sprites = ([ computer.name, conversations.pluck(:durable_id).compact ] if computer&.sprites?)
    end

    def remove_sprites
      ComputerRemovalJob.perform_later(user, id, *@sprites) if @sprites&.last.present?
    end

    def name_email
      self.email_name = Agent.email_name_for(name) if email_name.blank?
    end

    def leave_email_name
      self.former_email_names = (former_email_names | [ email_name_in_database ]) - [ email_name ]
    end

    def keeps_computer_folder
      return unless email_name_fixed?
      errors.add(:email_name, "can't change while its computer is install-managed SSH: the computer's folder is named after the address")
    end

    def mail_goes_one_step
      if mail_to_agent == self || mail_to_agent.workspace_id != workspace_id
        errors.add(:mail_to_agent, "must be another agent of the same workspace")
      elsif mail_to_agent.mail_to_agent_id || mail_from_agents.exists?
        errors.add(:mail_to_agent, "can't be part of a chain: mail goes one step, to an agent that keeps it")
      end
    end

    def tools_are_catalogued
      (Array(tool_names) - Tool::Catalog.names).each { errors.add(:tool_names, "includes #{it}, which is not a tool") }
    end

    def capabilities_are_allowed
      errors.add(:capabilities, "repeat one") if Array(capabilities).uniq.size != Array(capabilities).size
      (Array(capabilities) - Agent.capability_names).each { errors.add(:capabilities, "include #{it}, which is not available") }
    end

    # Its notes by key and the day each last changed, newest first, so it knows
    # what it has without looking; never a body, so a note saved from an email
    # can't steer every reply. It reads one whole with list_notes and its key.
    def notes_listing
      return "" unless tool_names.include?("list_notes") && !tool_off?("list_notes")
      listed = notes.order(updated_at: :desc).limit(NOTES_LISTED).pluck(:key, :updated_at)
      return "" if listed.empty?
      older = notes.count - listed.size
      [ "\n\nYour notes, newest first, with the day each last changed. Read one whole with list_notes and its key when it may help, " \
        "before asking the person something they may have told you.", "",
        *listed.map { |key, at| "- #{key} (#{at.in_time_zone(time_zone).to_date.iso8601})" },
        ("- and #{older} older: list_notes finds them" if older.positive?) ].compact.join("\n")
    end

    # One line for each connector that stopped being core for it on its own
    # (Agent::ConnectorMove), saying how to reach its tools now. It changes only
    # when such a move does, which changes its tools anyway (docs/prompt-cache.md).
    def lookup_note
      ids = core_server_ids
      names = connector_moves.includes(:mcp_server).select { it.in_effect?(ids) }.map(&:connector_name).uniq.sort
      return "" if names.empty?
      reach = "find one with tool_search and call it by its name" +
        (codemode? ? ", or from a codemode script find it with searchTools() and call it as tools.<name>(...)" : "")
      "\n\n" + names.map { "#{it}'s tools are looked up now, not among your tools, since they no longer fit beside them: #{reach}." }.join("\n")
    end

    # pi's <available_skills> block (system-prompt.ts formatSkillsForPrompt),
    # names and descriptions only: the bodies are read through read_skill, so
    # the instructions stay short and a skill's edit reaches the next reply.
    # A skill waiting for review, or rejected, is not listed (Skill::Review).
    def skills_listing
      ready = skills.ready.to_a
      return "" if ready.empty?
      entries = ready.map do |skill|
        "  <skill>\n    <name>#{skill.name.encode(xml: :text)}</name>\n    <description>#{skill.description.encode(xml: :text)}</description>\n  </skill>"
      end
      [ "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Use the read_skill tool to load a skill when the task matches its description.", "",
        "<available_skills>", *entries, "</available_skills>" ].join("\n")
    end
end
