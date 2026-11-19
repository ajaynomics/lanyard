# A connector: an MCP server whose tools a workspace's conversations may use.
# A remote one has a `url`; pi's
# `command` entry runs on each conversation's own computer instead, never here.
# Like pi's mcp.json, there are two levels: the workspace's, which every one
# of its conversations gets, and one conversation's (conversation_id), which replaces a
# same-named one of the workspace's or, with no address, only switches it off for
# that conversation. Its `user` is who added it; its members all manage it
# (docs/design/workspaces.md, section 2.4).
#
# Rails is the client, through the official `mcp` gem, which also does the MCP
# sign-in (McpServer::Authorization keeps what it learns here, encrypted). A
# refresh lists the server's tools and keeps them, so building a definition
# never waits on the network; each call then goes through the Invocation ledger.
# A command connector is reached through the sidecar (CommandTransport), on
# the computer of the conversation it serves.
class McpServer < ApplicationRecord
  # Room for `mcp__<name>__` and a readable tool name inside the sidecar's 64.
  NAME = /\A[a-z][a-z0-9_]{0,19}\z/
  LOCAL_HOSTS = %w[ localhost 127.0.0.1 ::1 [::1] ].freeze
  TIMEOUT = 30 # seconds, for each request and any stream the server holds open
  RENEW_BEFORE = 1.minute
  # Google issues a refresh token only to a sign-in that asks for offline
  # access with consent, and asks which account only when told to, which a
  # second account of one service needs. The `mcp` gem has no setting for
  # extra authorization parameters, so they are added to the address it hands us.
  AUTHORIZATION_PARAMS = { "accounts.google.com" => { "access_type" => "offline", "prompt" => "consent select_account" } }.freeze

  # Anything the server or the wire can go wrong with, as one plain message.
  class Unreachable < StandardError; end
  # The server wants a person to sign in, which only a person can start.
  class SignInNeeded < Unreachable; end
  FAILURES = [ MCP::Client::RequestHandlerError, MCP::Client::ServerError, MCP::Client::ValidationError,
               MCP::Client::PaginationLimitError, MCP::Client::InputRequiredError, MCP::Client::OAuth::Flow::AuthorizationError,
               Faraday::Error, JSON::ParserError ].freeze

  belongs_to :user
  belongs_to :conversation, optional: true
  belongs_to :workspace
  # Made through a person alone, it is in their personal workspace.
  before_validation { self.workspace ||= conversation ? conversation.workspace : user&.personal_workspace }
  # The agents it is core for: a workspace's connector only (Agent::CoreConnector).
  has_many :core_connectors, class_name: "Agent::CoreConnector", dependent: :delete_all
  has_many :connector_moves, class_name: "Agent::ConnectorMove", dependent: :nullify
  encrypts :token
  serialize :headers, coder: JSON
  serialize :oauth_client, coder: JSON
  serialize :oauth_tokens, coder: JSON
  serialize :oauth_pending, coder: JSON
  serialize :env, coder: JSON
  encrypts :headers, :oauth_client, :oauth_tokens, :oauth_pending, :env

  # A client the person registered with the service themselves, for one that
  # offers no dynamic registration (Slack, GitHub); pi's `oauth.clientId`.
  attribute :client_id, :string
  attribute :client_secret, :string

  # Both Connectors pages, and each conversation's page for its Connectors button,
  # follow a change a person can see. A token renewed before a call is not one.
  after_commit :broadcast_change, unless: -> { !destroyed? && saved_changes.except("oauth_tokens", "updated_at").none? }

  scope :global, -> { where(conversation_id: nil) }

  normalizes :token, :client_id, :client_secret, :command, :cwd, with: -> { it.strip.presence }
  normalizes :vault_entry, with: -> { it.squish.presence }
  validates :name, format: { with: NAME, message: "must start with a letter and use only a-z, 0-9 and _ (up to 20)" },
    uniqueness: { scope: %i[ workspace_id conversation_id ], message: "is taken by another connector here; give this one its own" }
  validate :url_is_https, if: -> { url.present? || (enabled? && !command?) }
  validate :switches_off_only_for_a_conversation, if: :switch_off?
  validate :url_or_command
  validate :x_keys, if: :x?
  # The vault entry that holds its OAuth app (McpServer::Clio), by name.
  validates :vault_entry, presence: true, length: { maximum: 200 }, if: :clio?
  validate :added_in_its_workspace, on: :create
  validate :app_is_the_gallerys, if: :oauth_app
  validate :fits_the_agents, if: -> { tools_changed? || loaded_changed? || disabled_tools_changed? }
  # Only when it is turned on: one already on and losing its key is switched off by install_for instead.
  validate :has_a_key_here, if: -> { install && !conversation && enabled? && (new_record? || will_save_change_to_enabled?) }

  # Only when pasted: the sign-in that follows, on this same record, binds the
  # registration to its issuer, and keeping it again would undo that.
  before_save :keep_own_client, if: -> { client_id && will_save_change_to_client_id? }

  # The redirect address registered with every authorization server: one
  # route on this app's public origin (APP__URL).
  def self.redirect_uri
    URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.connectors_callback_path).to_s
  end

  # What this install tells a sign-in server about itself, whether it registers
  # (dynamic registration) or reads it from client_metadata_url.
  def self.client_metadata
    app = DurableAssistants.config(:app, :url).to_s
    { client_name: DurableAssistants.config(:app, :name), client_uri: app,
      logo_uri: URI.join(app, "/apple-touch-icon.png").to_s,
      redirect_uris: [ redirect_uri ], grant_types: %w[ authorization_code refresh_token ], response_types: %w[ code ],
      token_endpoint_auth_method: "none" }
  end

  # The install's Client ID Metadata Document, which a sign-in server that
  # supports one uses instead of a registration; the gem keeps to registration
  # for any other. Only an https address can be one, so not in development.
  def self.client_metadata_url
    url = URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.connectors_client_path).to_s
    url if MCP::Client::OAuth::Discovery.client_id_metadata_document_url?(url)
  end

  # The office's connectors (config/install_connectors.yml): a workspace has
  # each one its owner, or the install's owner, turned on (turn_on), in the
  # workspace owner's name, on for all its agents and switched off for one as
  # any connector is. Its address may be plain http
  # inside the host; its key is read from settings on each use and never kept;
  # `tools` are the patterns an agent's tools must match; `loaded`, if given,
  # decides for each of the workspace's agents whether they are core, in every
  # request, where they fit, or looked up (Tool::FindTools). Nobody can
  # change or remove one; without its key, it goes from everyone.
  #
  # The install's own key is its owner's: only a workspace the install's owner
  # owns uses it (Workspace#installs_keys?). Any other workspace sets its own
  # address and key for one (Workspace::InstallConnector): its connector then
  # uses those, and may be turned on even where the install's key is not set.
  #
  # An agent may act as itself instead (docs/office.md): its conversation's
  # own connector naming the entry, with the agent's key as its token. The
  # entry's address and tool patterns hold for it whether or not the shared
  # key is set.
  def self.install_entries
    DurableAssistants.config(:install_connectors, default: {}).to_h.transform_keys(&:to_s)
      .select { |_, entry| entry[:url].present? }
  end

  # Keeps each office connector a workspace has following the install: its
  # address and the install's word on core. One whose entry, or every key for
  # it, is gone goes. One the workspace may no longer use the install's key
  # for is switched off, never deleted, and the log says so once. It never
  # makes one, nor switches one back on: that is a person's choice (turn_on).
  # A workspace whose owner was deleted has nobody to hold them, and is left as it is.
  def self.install_for(workspace)
    return unless workspace.owner
    usable = workspace.install_entries.select { |_, entry| entry[:api_key].present? }
    keyed = install_entries.select { |_, entry| entry[:api_key].present? }.keys | usable.keys
    installed = workspace.mcp_servers.global.where.not(install: nil)
    installed.where.not(install: keyed).destroy_all
    installed.where(install: keyed).find_each do |connector|
      if (entry = usable[connector.install]) then connector.follow_install_entry(entry)
      else connector.switch_off_without_a_key
      end
    end
  end

  # Turns the office connector on in the workspace: made in its owner's name,
  # or one switched off switched back on. Refused, with the connector's errors,
  # where the workspace has no key for it.
  def self.turn_on(workspace, name)
    entry = workspace.install_entries[name] or raise ActiveRecord::RecordNotFound, "The install has no connector #{name}"
    connector = workspace.mcp_servers.global.find_or_initialize_by(name: name, install: name) { it.user = workspace.owner }
    created = connector.new_record?
    connector.tap { it.follow_install_entry(entry, created:) if it.update(url: it.url || entry[:url], enabled: true) }
  end

  def follow_install_entry(entry, created: false)
    if created || url != entry[:url]
      update!(url: entry[:url], tools: [], refreshed_at: nil)
      McpServerRefreshJob.perform_later(self)
    end
    follow_install_word(entry[:loaded], created:) if entry.key?(:loaded)
  end

  # Without validations: one an earlier release made must go off even if it
  # would no longer pass them, or the sweep would stop at it.
  def switch_off_without_a_key
    return unless enabled?
    update_attribute(:enabled, false)
    Rails.logger.info "Switched off office connector #{install} (#{id}) in workspace #{workspace_id}: " \
      "the install's key is only for its owner's workspaces, and this one has none of its own"
  end

  # Its entry as its workspace has it: the workspace's own address and key, or the install's.
  def install_entry = (workspace.install_entries[install] if install)

  # Names and literal addresses only, so a mistake shows on the form; a
  # public name that resolves to a private address is refused when it is
  # reached (Address).
  def self.internal?(host)
    host = host.downcase.delete_suffix(".").delete("[]")
    return true if LOCAL_HOSTS.include?(host) || host.end_with?(".localhost")
    address = IPAddr.new(host).then { it.ipv4_mapped? ? it.native : it }
    address.loopback? || address.private? || address.link_local? || address.to_i.zero?
  rescue IPAddr::InvalidAddressError
    # 2130706433, 0x7f.1 or 0177.0.0.1: a resolver reads these as addresses IPAddr will not.
    host.match?(/\A(0x\h+|\d+)(\.(0x\h+|\d+))*\z/)
  end

  # The host of the install's own address for the entry, which may be inside the host.
  def self.install_host(name)
    URI.parse(install_entries.dig(name, :url).to_s).host
  rescue URI::InvalidURIError
    nil
  end

  # Inside the install, so reached over plain http and not pinned: the
  # entry's own host, or one the operator lists (InternalHosts).
  def self.inside_the_install?(name, uri)
    uri.host.present? && (uri.host == install_host(name) || InternalHosts.include?(uri))
  end

  # Core is applied when the connector is made, when the install changes its
  # word, and for each agent made later (Agent's after_create); never merely
  # because a run sees it. One an earlier release left looked up (it did not
  # fit every agent) has no word recorded, so deploying this release grows no
  # agent's tools. Lookup, which only lowers counts, is applied every run.
  def follow_install_word(core, created: false)
    changed = !install_core.nil? && install_core != core
    follow_install(core) if created || changed || !core
    update_column(:install_core, core) unless install_core == core
  end

  # The install's word on an office connector: core for each of the workspace's
  # agents where it fits, or lookup for all of them.
  def follow_install(core)
    core ? workspace.agents.each { make_core_for(it) } : core_connectors.delete_all
  end

  # Core for the agent where it fits beside its other tools; where it does
  # not, it stays lookup, and the agent's Tools say why, once.
  def make_core_for(agent)
    return true if agent.core?(self)
    made = agent.core_connectors.create(mcp_server: self)
    return true if made.persisted?
    moved_for(agent, made.errors.full_messages.to_sentence) unless agent.connector_moves.exists?(mcp_server: self)
    false
  end

  # The agents it is core for (Agent#core?).
  def core_agents
    if conversation then [ conversation.agent ].select { it.core?(self) }
    else workspace.agents.where(id: core_connectors.select(:agent_id)).to_a
    end
  end

  # An office connector offers only the tools its patterns match (shell globs,
  # File.fnmatch with {a,b}); any other offers every tool its server lists.
  def offered?(tool_name)
    patterns = install_entry&.dig(:tools) or return true
    patterns.any? { File.fnmatch?(it, tool_name, File::FNM_EXTGLOB) }
  end

  # The gallery entry it was added from, as [key, entry], known by its
  # address: a second account of one service has the same one, under its own
  # name. Two entries for one service differ in what they ask for, their scope.
  def gallery
    entries = DurableAssistants.config(:connectors, :gallery, default: {}).select { |_, entry| entry[:url] == url }
    entries.find { |_, entry| entry[:scope] == oauth_scope } || entries.first
  end

  # A gallery entry (config/connectors.yml) as a connector's attributes.
  # An IMAP entry has no address of its own: the person's server and username make it.
  def self.gallery_attributes(key, host: nil, port: nil, username: nil)
    entry = DurableAssistants.config(:connectors, :gallery, key.to_s.to_sym) or raise ActiveRecord::RecordNotFound, "No gallery entry #{key}"
    url = entry[:imap] ? Imap.address(host:, port:, username:) : entry[:url]
    { url: url, oauth_scope: entry[:scope], oauth_app: entry[:app] }.compact
  end

  # Whether this instance has the named OAuth app.
  def self.instance_app?(name) = DurableAssistants.config(:connectors, :apps, name.to_s.to_sym, :client_id).present?

  # Lists the server's tools and keeps them, or keeps why it could not. Network
  # work, so it runs in McpServerRefreshJob, never inside a transaction. A
  # command connector runs on a conversation's computer: its own, or for a
  # person's connector, the conversation the refresh was asked from.
  def refresh(conversation = self.conversation)
    return refresh_google if google
    return refresh_imap if imap?
    return refresh_x if x?
    return refresh_clio if clio?
    listed = connect(conversation:) { it.tools }.select { offered?(it.name) }.map do
      { "name" => it.name, "description" => it.description.to_s, "input_schema" => it.input_schema || {},
        "annotations" => it.annotations || {} }
    end
    # A server that lists its tools to anyone (Google's do) answers a
    # connector with no tokens too, and that must not undo a sign-out.
    self.attributes = { tools: listed, refreshed_at: Time.current }
    self.attributes = { refresh_error: nil, sign_in_needed: false } unless signed_out?
    move_where_it_no_longer_fits_and_save
  rescue Unreachable => problem
    record_problem problem.message, sign_in: problem.is_a?(SignInNeeded), refreshed_at: Time.current
  rescue ActiveRecord::RecordInvalid
    record_problem errors.full_messages.to_sentence, refreshed_at: Time.current
  end

  def refreshing? = !switch_off? && refreshed_at.nil?

  # One call to one of its tools for a conversation; the raw JSON-RPC result, for
  # Tool::Mcp to read. A call that fails says so on the connector, and one
  # that succeeds clears a failure that is no longer true.
  def call_tool(name, arguments, conversation: self.conversation)
    result = if google then Google.new(self).call_tool(name, arguments)
    elsif imap? then Imap.new(self).call_tool(name, arguments)
    elsif x? then X.new(self).call_tool(name, arguments)
    elsif clio? then Clio.new(self).call_tool(name, arguments)
    else connect(conversation:) { it.call_tool(name: name, arguments: arguments) }.fetch("result") { raise Unreachable, "#{self.name} sent no result." }
    end
    update!(refresh_error: nil, sign_in_needed: false) if (refresh_error || sign_in_needed?) && !signed_out?
    result
  rescue Unreachable => problem
    record_problem problem.message, sign_in: problem.is_a?(SignInNeeded)
    raise
  end

  # Pi's /mcp states, in this app's words. `refresh_error`
  # is why the last refresh or call failed. With a conversation, a command
  # connector it cannot run says so.
  def status(conversation = nil)
    if !enabled? then "off"
    elsif conversation && !usable_by?(conversation) then "no_computer"
    elsif needs_sign_in? then "needs_sign_in"
    elsif refresh_error.present? then "failing"
    elsif refreshing? then "listing"
    else "ok"
    end
  end

  def needs_attention?(conversation = nil) = status(conversation).in?(%w[ needs_sign_in failing ])

  def command? = command.present?

  # pi's project entry with no address: it only switches the person's connector off for one conversation.
  def switch_off? = url.blank? && !command?

  # A command connector runs only on a computer, so a conversation without one that is on gets none of its tools.
  def usable_by?(conversation) = !command? || conversation.agent.computer&.on? == true

  # What the sidecar starts on the agent's computer: pi's entry.
  def launch = { command: command, args: args, env: env || {}, cwd: cwd }

  # Every tool it listed, each answering like a Tool class, and those its
  # agents get: not one the person turned off for every agent.
  def listed_tools = listing.map { Tool::Mcp.new(self, it) }

  def listing
    if google then Google.listing(google).select { offered?(it["name"]) && Google.allowed?(google, it["name"], oauth_scope) }
    elsif imap? then Imap::TOOLS
    elsif x? then X::TOOLS
    elsif clio? then Clio::TOOLS
    else tools
    end
  end

  # :gmail, :calendar, :drive or :chat for a connector to Google's hosted servers, which this
  # app answers through Google's plain APIs instead (McpServer::Google).
  def google = Google.kind(url)
  # A mailbox read over IMAP, headers only, answered here too (McpServer::Imap).
  def imap? = Imap.imap?(url)
  def x? = X.x?(url)
  # Clio Manage through its API, with its own OAuth app from the vault (McpServer::Clio).
  def clio? = Clio.clio?(url)
  # Tools this app lists itself, so their flags (asks every time) are its own, not a server's claim.
  def own_listing? = google.present? || imap? || x? || clio?
  def tool_classes = listed_tools.reject { tool_off?(it.listing["name"]) }

  def tool_off?(name) = disabled_tools.include?(name)

  def signed_in? = oauth_tokens.present?

  # No pasted header, no sign-in, and the server asked for one (sign_in_needed), the
  # person started one and did not finish it, or the connector was set up to sign
  # in (an instance app, a scope or a client): Google lists its tools to anyone and
  # refuses only when one is called, so a 401 alone would not tell us.
  def needs_sign_in? = url.present? && !authorized_by_header? && !signed_in? &&
    (sign_in_needed? || oauth_state.present? || signs_in?)

  def signs_in? = oauth_app.present? || oauth_scope.present? || oauth_client.present? || clio?

  # Set up to sign in, holding no tokens: only a sign-in changes that.
  def signed_out? = signs_in? && !signed_in? && !authorized_by_header?

  # What goes with every request: pi's `headers`, and the token field as a bearer header.
  def request_headers = (headers || {}).merge(install_entry&.dig(:api_key) ? { "Authorization" => "Bearer #{install_entry[:api_key]}" } : {})
    .merge(token ? { "Authorization" => "Bearer #{token}" } : {})

  # As in pi, OAuth applies only to a server without an Authorization header.
  def authorized_by_header? = request_headers.keys.any? { it.casecmp?("authorization") }

  def signed_in_at = oauth_tokens && Time.zone.at(oauth_tokens["signed_in_at"].to_i)

  # The instance's own app, for a connector made from a gallery entry that
  # names one. Read from settings on each use; the row keeps only the name.
  def instance_client
    app = DurableAssistants.config(:connectors, :apps, oauth_app.to_sym) if oauth_app
    return unless app && app[:client_id].present?
    { "client_id" => app[:client_id], "client_secret" => app[:client_secret].presence,
      "token_endpoint_auth_method" => app[:client_secret].present? ? "client_secret_post" : "none" }.compact
  end

  # Starts a sign-in: the address of the service's sign-in page to send the
  # person to, or nil when the server let us in without one. The `mcp` gem
  # does the work: the 401, discovery, registration, PKCE and `state`.
  def sign_in_url
    return Clio.new(self).sign_in_url if clio?
    update!(oauth_tokens: nil)
    connect(signing_in: true) { nil }
    started_without_a_challenge if signs_in?
  rescue MCP::Client::OAuth::Flow::AuthorizationPendingError => pending
    with_authorization_params(pending.authorization_url)
  end

  # A server that lists its tools without a 401 gives the gem nothing to start
  # from, so a connector set up to sign in starts from the server's published
  # metadata instead, as it would after a challenge.
  def started_without_a_challenge
    flow = MCP::Client::OAuth::Flow.new(provider: authorization(signing_in: true).provider)
    with_authorization_params(flow.authorization_url) if flow.run!(server_url: canonical_url, scope: oauth_scope.presence) == :redirect
  end

  # Completes the sign-in with the service's redirect back to us.
  def finish_sign_in(callback_params)
    return Clio.new(self).finish_sign_in(callback_params.to_h.stringify_keys) if clio?
    MCP::Client::OAuth::Flow.new(provider: authorization.provider)
      .finish!(server_url: canonical_url, callback_params: callback_params.to_h)
    # Without one the sign-in lapses with its first token, in about an hour.
    Rails.logger.warn "Google connector #{id} signed in without a refresh token" if google && oauth_tokens&.dig("refresh_token").blank?
  rescue MCP::Client::OAuth::Flow::AuthorizationError => problem
    raise Unreachable, "Could not sign in to #{name}: #{problem.message}".truncate(500)
  end

  # Forgets the tokens, as pi's logout does. The registration stays for the
  # next sign-in, and its tools stay listed, offered to no agent until then (Agent#tools).
  def sign_out
    update!(oauth_tokens: nil, refresh_error: "Signed out.", sign_in_needed: true, refreshed_at: Time.current)
  end

  def to_s = name

  # Outside development a person's server is reached only at a public address
  # (Address); the install's own may be on its private network. A workspace's
  # own address for an office connector is a person's, unless the operator
  # lists its host (InternalHosts).
  def pinned? = !at_install_host? && !Rails.env.local?

  def at_install_host?
    install.present? && self.class.inside_the_install?(install, URI.parse(url.to_s))
  rescue URI::InvalidURIError
    false
  end

  private
    def authorization(signing_in: false) = Authorization.new(self, signing_in: signing_in)

    def canonical_url = MCP::Client::OAuth::Discovery.canonicalize_url(url)

    def connect(signing_in: false, conversation: self.conversation)
      transport = command? ? CommandTransport.new(self, conversation) : http_transport(signing_in)
      client = MCP::Client.new(transport: transport)
      # The 2025 handshake every current server speaks; :auto would probe the
      # 2026 discovery first and fall back to this anyway.
      client.connect(client_info: { name: "durable-assistants", version: "1" }, mode: :legacy)
      yield client
    rescue MCP::Client::RequestHandlerError => failure
      raise Unreachable, "#{name} refused its Authorization header." if failure.error_type == :unauthorized && authorized_by_header?
      raise SignInNeeded, "#{name} needs you to sign in." if failure.error_type == :unauthorized
      raise Unreachable, "Could not reach #{name}: #{failure.original_error.message}" if failure.original_error.is_a?(Address::Refused)
      raise_timed_out if failure.original_error.is_a?(Faraday::TimeoutError)
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    rescue Faraday::TimeoutError
      raise_timed_out
    rescue MCP::Client::ServerError => failure
      raise_timed_out failure.data["seconds"] if command? && failure.code == CommandTransport::TIMED_OUT && failure.data.is_a?(Hash)
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    rescue *FAILURES => failure
      raise Unreachable, "Could not reach #{name}: #{failure.message}".truncate(500)
    ensure
      close transport
    end

    # A server cut off at the limit was slow, not down: it often answers moments
    # later, so the agent must not read this as a server that is gone.
    def raise_timed_out(seconds = TIMEOUT) = raise(Unreachable, "#{name} timed out after #{seconds}s (the server may still be working).")

    # Its tools are this app's own; the refresh only checks the password works.
    def refresh_imap
      Imap.new(self).check
      update!(tools: Imap::TOOLS, refreshed_at: Time.current, refresh_error: nil)
    rescue Unreachable => problem
      record_problem problem.message, tools: Imap::TOOLS, refreshed_at: Time.current
    end

    # Nothing to ask X: its tools are this app's own, and a call costs money.
    def refresh_x
      update!(tools: X::TOOLS, refreshed_at: Time.current, refresh_error: nil, sign_in_needed: false)
    end

    # Nothing to ask Clio before a call: its tools are this app's own list.
    def refresh_clio
      self.attributes = { tools: Clio::TOOLS, refreshed_at: Time.current }
      self.attributes = { refresh_error: nil, sign_in_needed: false } unless signed_out?
      move_where_it_no_longer_fits_and_save
    end

    # Nothing to ask Google: its tools are this app's own list.
    def refresh_google
      self.attributes = { tools: Google.listing(google).select { offered?(it["name"]) }, refreshed_at: Time.current }
      self.attributes = { refresh_error: nil, sign_in_needed: false } unless signed_out?
      move_where_it_no_longer_fits_and_save
    end

    def http_transport(signing_in)
      oauth = authorization(signing_in:).provider if !authorized_by_header? && (signing_in || signed_in?)
      renew(oauth) if oauth && expiring?
      MCP::Client::HTTP.new(url: url, headers: request_headers, oauth: oauth,
        max_reconnection_wait: TIMEOUT) do |faraday|
        faraday.options.timeout = TIMEOUT
        Address.pin(faraday) if pinned?
      end
    end

    def expiring?
      expires_at = oauth_tokens&.dig("expires_at")
      expires_at.present? && oauth_tokens["refresh_token"].present? && Time.zone.at(expires_at) < RENEW_BEFORE.from_now
    end

    # Renews a token about to expire. If that fails, the call meets a 401, and
    # the gem refreshes once more or the person is asked to sign in again.
    def renew(oauth)
      MCP::Client::OAuth::Flow.new(provider: oauth).refresh!(server_url: canonical_url)
    rescue MCP::Client::OAuth::Flow::AuthorizationError
      nil
    end

    # Ending the session is a courtesy; a server that refuses it changes nothing here.
    def close(transport)
      transport&.close
    rescue *FAILURES
      nil
    end

    # A server that wants a sign-in has refused any tokens we hold, so they are
    # forgotten: the connector says "needs sign-in" however it was found out.
    def record_problem(message, sign_in: false, **changes)
      restore_attributes
      Rails.logger.warn "#{self.class.name} #{id} needs a new sign-in (#{message}); it held #{oauth_tokens&.dig("refresh_token").present? ? "a" : "no"} refresh token" if sign_in
      update!(refresh_error: message, sign_in_needed: sign_in, **changes, **(sign_in ? { oauth_tokens: nil } : {}))
    end

    def broadcast_change = workspace.members.each { broadcast_refresh_later_to(it, :connectors) }

    def with_authorization_params(url)
      uri = URI(url.to_s)
      extra = AUTHORIZATION_PARAMS.fetch(uri.host, {})
      params = URI.decode_www_form(uri.query.to_s).to_h
      uri.query = URI.encode_www_form(extra.merge(params)) if extra.any?
      uri.to_s
    end

    def keep_own_client
      self.oauth_client = { "client_id" => client_id, "client_secret" => client_secret,
        "token_endpoint_auth_method" => client_secret ? "client_secret_post" : "none" }.compact
    end

    # The token goes in a header, so plain http is allowed only to this
    # machine. Rails makes the requests from inside the server's network, so
    # outside development a person's connector may not reach this machine or
    # a private address; only the install's own may.
    def url_is_https
      return imap_address if imap?
      uri = URI.parse(url.to_s)
      return if at_install_host? && uri.is_a?(URI::HTTP)
      return errors.add(:url, "can't be this server or its private network") if uri.host.present? && self.class.internal?(uri.host) && !Rails.env.local?
      return if uri.is_a?(URI::HTTPS) && uri.host.present?
      return if uri.is_a?(URI::HTTP) && LOCAL_HOSTS.include?(uri.host)
      errors.add(:url, "must start with https://")
    rescue URI::InvalidURIError
      errors.add(:url, "is not a web address")
    end

    # imaps://<username>@<host>:<port>, to a public name outside development,
    # with the password as the token.
    def imap_address
      uri = URI.parse(url)
      errors.add(:url, "needs a mail server, a username and a password") if uri.host.blank? || uri.user.blank? || token.blank?
      errors.add(:url, "can't be this server or its private network") if uri.host.present? && self.class.internal?(uri.host) && !Rails.env.local?
      errors.add(:url, "has a port out of range") unless (1..65_535).cover?(uri.port || Imap::PORT)
    rescue URI::InvalidURIError
      errors.add(:url, "is not a mail server's address")
    end

    # The instance's secret goes only to the server its gallery entry names.
    def app_is_the_gallerys
      urls = DurableAssistants.config(:connectors, :gallery, default: {}).values.select { it[:app] == oauth_app }.pluck(:url)
      errors.add(:base, "Only a gallery connector can use this instance's #{oauth_app} app") unless urls.include?(url)
    end

    def switches_off_only_for_a_conversation
      errors.add(:url, "can't be blank") unless conversation && !enabled?
    end

    def has_a_key_here
      return if install_entry&.dig(:api_key).present?
      # Saying the install's key is kept from it would mislead where the install has none at all (#241).
      why = McpServer.install_entries.dig(install, :api_key).present? ? "the install's is only for the install owner's workspaces" : "the install has none of its own"
      errors.add(:base, "#{name} needs this workspace's own key: #{why}")
    end

    def x_keys
      keys = JSON.parse(token.to_s) rescue {}
      errors.add(:token, "needs X's four values: consumer key and secret, access token and secret") unless keys.is_a?(Hash) && X::KEYS.all? { keys[it].present? }
    end

    def url_or_command
      errors.add(:base, "Give a web address or a command, not both") if url.present? && command?
    end

    # By one of its members, for one of its conversations. Only when added: a
    # member who leaves does not take what they added with them.
    def added_in_its_workspace
      errors.add(:conversation, "is not in this workspace") if conversation && conversation.workspace != workspace
      errors.add(:user, "is not in this workspace") if user && workspace && !workspace.member?(user)
    end

    # The sidecar refuses a definition with more than its limit of tools, so
    # this counts all the agent would send (Agent#tools), its skills, channels
    # and saved sign-ins included. Only the agents it is core for: for any
    # other it is lookup and counts none of its own (any number of them add
    # find_tools and use_tool, two in all), so another agent near the limit
    # never refuses it. A conversation's own is its agent's alone.
    def fits_the_agents
      past_the_limit.each do |agent, count|
        errors.add(:base, "#{name} offers #{tools.size} tools; #{agent} can have #{Agent::TOOL_LIMIT} in all and would have #{count}")
      end
    end

    # Each agent that it is core for and that it takes past the limit, with
    # how many tools that agent would want.
    def past_the_limit
      # Afresh: an agent the person holds may have gained a skill or a channel since.
      agents = conversation ? [ conversation.agent ] : (persisted? ? workspace.agents.where(id: core_connectors.select(:agent_id)).to_a : [])
      agents.filter_map do |agent|
        # Each of the agent's conversations, with its own connectors too, as
        # Agent#tools_fit counts them; the workspace's, before it has one.
        sets = conversation ? [ conversation.connectors ] : agent.conversations.map(&:connectors).presence || [ workspace.mcp_servers.global.select(&:enabled?) ]
        count = sets.map do |set|
          agent.wanted_tool_count(set.reject { |other| other == self || other.name == name } + [ self ].select(&:enabled?), signed_out: true)
        end.max
        [ agent, count ] if count > Agent::TOOL_LIMIT
      end
    end

    # A refresh that would take an agent past the limit no longer fails: for each
    # such agent, and that agent only, it is looked up instead, and the move
    # recorded (Agent::ConnectorMove). Another agent it is core for keeps it.
    def move_where_it_no_longer_fits_and_save
      transaction do
        past_the_limit.each do |agent, count|
          next if conversation && !loaded?
          conversation ? self.loaded = false : core_connectors.where(agent: agent).delete_all
          moved_for(agent, "It now offers #{tool_classes.size} tools: core, it would give #{agent} #{count}, and an agent can have #{Agent::TOOL_LIMIT}.")
        end
        save!
      end
    end

    def moved_for(agent, reason)
      agent.connector_moves.create!(mcp_server: self, connector_name: name, reason: reason.truncate(500))
    end
end
