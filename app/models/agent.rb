class Agent < ApplicationRecord
  include Pausable
  include LinkedCalendar
  include SendingHours
  include Movable

  # Every level pi-ai knows, in order, as people read them. Which of them a
  # model supports is pi-ai's fact (ModelCatalog); the sidecar runs a model at
  # its nearest supported level, so a level is never a reason to refuse an agent.
  THINKING_LEVEL_NAMES = { "off" => "Off", "minimal" => "Minimal", "low" => "Low", "medium" => "Medium",
                           "high" => "High", "xhigh" => "Extra high", "max" => "Maximum" }.freeze
  THINKING_LEVELS = THINKING_LEVEL_NAMES.keys.freeze
  TOOL_LIMIT = 64 # the most the sidecar installs for one agent (agent/runtime.mjs)
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
  # Its mail accounts and calendar servers, which only the workspace's owner
  # sets (Agent::MailAccount, Agent::CalendarServer): its own, which it sends
  # and writes through, and any it only reads, such as a colleague's whose work
  # it took over. `mail_account` and `calendar_server` are always its own.
  has_many :mail_accounts, class_name: "Agent::MailAccount", dependent: :destroy
  has_one :mail_account, -> { where(read_only: false) }, class_name: "Agent::MailAccount", inverse_of: :agent, dependent: :destroy
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

  # Who it is to everyone it writes to: given when it is made, never changed
  # (an address that changed would strand every thread it is in).
  attr_readonly :name, :email_name

  validates :name, :instructions, presence: true
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
  # The person may choose it at New agent, as they type it: "Jordan@" is jordan@.
  normalizes :email_name, with: -> { it.strip.downcase.delete_suffix("@").presence }
  before_validation :name_email, on: :create
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

  # Its thread exists from the start; the sidecar admits it when first used (Conversation#admit!).
  after_create { conversations.create!(request_id: "thread") }
  after_create :carry_office_connectors
  # Where the install can sign in to Campfire, every new agent is a bot there too (docs/campfire.md).
  after_create_commit -> { CampfireBotJob.perform_later(self) }, if: -> { campfire.admin? }
  # Read before the conversations go; deleted after the agent is.
  before_destroy :remember_sprites, prepend: true
  after_destroy_commit :remove_sprites
  after_update -> { routines.each(&:replan) }, if: :saved_change_to_time_zone?
  after_update_commit -> { conversation&.broadcast_status_line }, if: -> { saved_change_to_model? || saved_change_to_thinking_level? }
  after_update_commit -> { conversation&.broadcast_row }, if: :saved_change_to_title?
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
  # agent (#core?): find_tools and use_tool reach their tools, and so does a
  # code mode script, as tools.<name> (#lookup_tools).
  # A tool the agent called through use_tool (activated, most recent last) is
  # declared as itself from the next message only where the person let it
  # (promotes_found_tools), as pi's deferred exposure does, while there is
  # room: the least recently used go first. use_tool then no longer offers
  # it, so the agent calls it directly. They are declared in name order, so
  # using one changes nothing the sidecar sees. A tool the person turned off,
  # for this agent (disabled_tools) or on its connector for every agent
  # (McpServer#tool_classes), is in neither list. Nor is a tool of a connector
  # that needs the person to sign in (McpServer#needs_sign_in?): a call could
  # only fail, and signing in brings them back. The limit still counts them
  # (signed_out: true), so signing in never takes an agent past it.
  #
  # Two or more Google connectors of one kind give one set of its tools, with
  # an account argument (Tool::Mcp::Group). Never more than TOOL_LIMIT are
  # declared, or the sidecar refuses every message: past it, the last core
  # connectors' tools are looked up instead, always the same ones, so nothing
  # is refused and nothing is lost; the agent's settings meter shows what it
  # wants (#wanted_tool_count).
  def tools(connectors, activated: [], signed_out: false) = toolset(connectors, activated:, signed_out:).first

  # What it declares, and the lookup tools a code mode script may call beside
  # them: those find_tools searches and it does not declare.
  def toolset(connectors, activated: [], signed_out: false)
    tools, searched = wanted_tools(connectors, signed_out:)
    if tools.size + (searched.any? ? 2 : 0) > TOOL_LIMIT
      searched = tools.drop(TOOL_LIMIT - 2) + searched
      tools = tools.first(TOOL_LIMIT - 2)
    end
    return [ tools, [] ] if searched.empty?
    found = promotes_found_tools? ? activated.reverse.filter_map { |name| searched.find { it.tool_name == name } } : []
    found = found.first([ TOOL_LIMIT - tools.size - 2, 0 ].max).sort_by(&:tool_name)
    declared = found.map(&:tool_name)
    lookup = searched.reject { declared.include?(it.tool_name) }
    finding = { codemode: codemode?, promotes: promotes_found_tools? }
    [ tools + [ Tool::FindTools.new(searched, declared: declared, **finding), Tool::UseTool.new(searched, **finding) ] + found, lookup ]
  end

  # How many tools it would declare were there no limit: what its settings'
  # meter and a connector's save count. `core` stands for the connectors core
  # for it, to ask what one more would do.
  def wanted_tool_count(connectors, signed_out: false, core: core_server_ids)
    tools, searched = wanted_tools(connectors, signed_out:, core:)
    tools.size + (searched.any? ? 2 : 0)
  end

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
  def own_tools
    own = built_in_tools + Tool::Catalog::ALWAYS + Tool::Catalog::CANVAS
    # A workflow's every step is a helper; the agent checks on and cancels its own.
    own.push(Tool::RunWorkflow, Tool::CheckHelper, Tool::CancelHelper) if capabilities.include?("subagents")
    own << Tool::ReadSkill if skills.ready.any?
    own.concat(Tool::Catalog::CARDS)
    own.concat(Tool::Catalog::QUESTIONS) if own.include?(Tool::AskPerson)
    own.concat(Tool::Catalog::CONCOURSE) if concourse_networks.any? && DurableAssistants::Concourse.configured?
    own.concat(Tool::Catalog::EMAIL) if sends_email?
    own.concat(Tool::Catalog::CAMPFIRE) if campfire_bot && campfire.configured?
    own.concat(Tool::Catalog::PHONE) if texts?
    own.concat(Tool::Catalog::TELEGRAM) if telegram_bot&.usable?
    own.concat(Tool::Catalog::CALENDAR) if calendar?
    own.concat(Tool::Catalog::SAVED_SIGN_INS) if computer&.on? && computer.sprites? && DurableAssistants::Passbolt.configured?(self)
    own.reject { tool_off?(it.tool_name) }.uniq(&:tool_name)
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
  def built_in_tools = tool_names.filter_map { Tool::Catalog.find(it) }.select(&:available?)

  def tool_off?(name) = disabled_tools.include?(name)

  # How many tools its thread declares, as its settings' meter counts them:
  # Agent#tools for the thread's connectors, find_tools and use_tool
  # included, and no tool the agent looked up, which only ever fills spare room.
  def tool_count = wanted_tool_count(default_connectors)

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
  # The tools are a conversation's (Conversation#definition). With code mode,
  # `lookup` carries the tools it looks up, which the sidecar lets a script
  # call and never offers the model (agent/extensions.mjs); without, or with
  # none, the key is left out, so the digest is as it was. Its workspace's
  # shared instructions follow its own, so a change to them reaches every
  # agent of that workspace on its next message. With helpers, `helperModels`
  # names the models they may run on (ModelCatalog.for_helpers); without, or
  # for a sidecar from before them, the key is left out likewise.
  def definition(tools, lookup: [], helper_models: capabilities.include?("subagents"))
    body = { instructions: identity + instructions + workspace.instructions_prompt + skills_listing + lookup_note + notes_listing, model: model, thinkingLevel: thinking_level,
             tools: tools.map(&:declaration), capabilities: capabilities, computer: computer&.descriptor }
    body[:lookup] = lookup.first(LOOKUP_LIMIT).map(&:declaration) if codemode? && lookup.any?
    body[:claudeRoute] = claude_route if claude_route
    body[:helperModels] = ModelCatalog.for_helpers if helper_models
    body.merge(digest: Agent::Canonical.digest(body))
  end

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
  # (Agent::CalendarServer) or else on the install's CalDAV server, and one
  # linked calendar from another account (Agent::LinkedCalendar): either
  # gives it the calendar tools, which see both as one set of lists
  # (docs/calendar.md). So do the lists of servers it only reads, beside them.
  def calendar? = own_calendar? || linked_calendar? || read_only_calendar_servers.any?
  def own_calendar? = own_calendar_server? || install_calendar?
  def own_calendar_server? = !!calendar_server&.usable?
  def install_calendar? = caldav_username.present? && caldav_password.present? && DurableAssistants::Caldav.configured?
  def caldav = DurableAssistants::Caldav::Combined.new(own_caldav, (linked_caldav if linked_calendar?), read_only_calendar_servers.map(&:caldav))
  def read_only_calendar_servers = calendar_servers.select { it.read_only? && it.usable? }

  # Those the clock reads for a task alarm (TaskAlarmSweepJob). Whether the
  # account or the server is usable now is #own_calendar?.
  scope :with_own_calendar, -> {
    where.not(caldav_username: nil).where.not(caldav_password: nil)
      .or(where(id: Agent::CalendarServer.where(read_only: false).select(:agent_id))) # tenancy-ok: the clock reads every owner's agents
  }

  # Whether a file a tool finds can be saved on its computer: only on a
  # Sprite that is on does the sidecar save one (agent/files.mjs).
  def saves_files? = computer&.on? == true && computer.sprites?

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

  # The address it goes by, as said to it and shown beside it.
  def own_address = mail_primary? ? mail_account.address : email_address

  # Its settings that only the owner of its workspace sees and changes, such
  # as its own mail account: another member uses the agent but cannot point
  # its mail, or the copy of it, elsewhere.
  def owned_by?(person) = person.present? && workspace.owner == person

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
  # person answered "Always". A tool that asks every time may still be covered
  # by an Always for each of its recipients (Tool.always_with_recipients), and
  # by nothing else.
  def allows?(tool)
    return true if tool.always_with_recipients? && granted_every_recipient?(tool)
    return false if tool.even_approving_everything?
    return true if workspace.approvals.allows?(tool)
    # A policy that approves everything runs it; under any other, no stored
    # Always does, whatever the tool says of always?.
    return false if tool.every_time?
    allows_always?(tool)
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
    def granted_recipients(tool) = permissions.where(tool_name: tool.permission_name).pluck(:recipient)

    def remember_sprites
      @sprites = ([ computer.name, conversations.pluck(:durable_id).compact ] if computer&.sprites?)
    end

    def remove_sprites
      ComputerRemovalJob.perform_later(user, id, *@sprites) if @sprites&.last.present?
    end

    def name_email
      self.email_name = Agent.email_name_for(name) if email_name.blank?
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
      reach = "find one with find_tools and call it with use_tool" +
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
