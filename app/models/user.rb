class User < ApplicationRecord
  include User::Wallet

  has_many :memberships, class_name: "Workspace::Membership", dependent: :destroy
  has_many :workspaces, through: :memberships
  has_many :owned_workspaces, -> { where(workspace_memberships: { role: "owner" }) }, through: :memberships, source: :workspace
  has_many :sent_invitations, class_name: "Workspace::Invitation", foreign_key: :inviter_id, inverse_of: :inviter, dependent: :destroy
  has_one :personal_membership, -> { joins(:workspace).where(workspaces: { personal: true }) }, class_name: "Workspace::Membership"
  has_one :personal_workspace, through: :personal_membership, source: :workspace
  # The agents in all their workspaces, and everything of them, for what is
  # the person's across workspaces (their badge, the model they used last). A
  # request reaches only its own workspace's (Current.workspace).
  has_many :agents, through: :workspaces
  has_many :conversations, through: :agents, source: :conversations
  has_many :payment_requests, through: :conversations
  # The calls waiting for them, across every agent (ConversationsController, as JSON).
  has_many :invocations, through: :conversations
  # Reached only through the person, so another's message is not found (AgentsController, from).
  has_many :messages, through: :conversations
  # Every agent's helpers and workflows' runs, for the person's Helpers panel.
  has_many :helpers, through: :conversations
  has_many :workflow_runs, through: :conversations
  # Every connector of their workspaces, each opened in its own (Authentication#find_in_workspace).
  has_many :connectors, through: :workspaces, source: :mcp_servers
  # The connectors they added, in any workspace; each is reached through its workspace (Workspace#mcp_servers).
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy
  # The browsers where they turned notifications on (Settings, Notifications).
  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all
  has_many :push_devices, class_name: "Push::Device", dependent: :delete_all
  # What became of turning on the phone app's notifications, the latest few (docs/native-app.md).
  has_many :push_attempts, class_name: "Push::Attempt", dependent: :delete_all
  # The Apple Watches they reach the app from, each with its own token (Settings, Apple Watch).
  has_many :watches, dependent: :delete_all
  # What the phone's Share sheet handed over, until it is sent or swept (Share).
  has_many :shares, dependent: :destroy
  has_many :ahoy_visits, class_name: "Ahoy::Visit", dependent: :delete_all
  has_many :ahoy_events, class_name: "Ahoy::Event", dependent: :delete_all
  # The agents they made (agents.user_id), which go with them. Never a lookup:
  # what a person reaches is their workspaces' agents.
  has_many :made_agents, class_name: "Agent", inverse_of: :user, dependent: :destroy

  NAME_LIMIT = 100

  validates :oidc_sub, presence: true
  validates :name, length: { maximum: NAME_LIMIT }

  # The one path that creates people, and so the one place a new person is
  # given the starter agent. `sub` is the subject the identity provider verified.
  def self.sign_in!(sub:, email:, name:)
    return signed_in_as_owner(email).tap(&:install_connectors) if Admission.owner && email.to_s.downcase != Admission.owner
    transaction do
      user = find_by(oidc_sub: sub) || claim_access_user(sub, email) || claim_owner(sub, email) || create!(oidc_sub: sub) # tenancy-ok: sign-in finds the person by the subject Ajent verified
      user.update!(email: email.to_s, name: user.named? ? user.name : name.to_s.presence || user.name.to_s)
      user.start_starter if user.agents.none?
      user
    end.tap(&:install_connectors)
  end

  # An install with an owner (ACCESS__OWNER_EMAIL) serves that one person:
  # everyone it admits signs in as them, to one set of agents, connectors and
  # threads, and never changes the owner's name or email. The owner's row is
  # theirs from their first sign-in, or held for them until it.
  def self.owner
    find_by(email: Admission.owner) || create!(oidc_sub: "owner:#{Admission.owner}", email: Admission.owner).tap { it.start_starter } # tenancy-ok: the install's one owner
  end

  # Someone else the install admits signs in as its owner, never silently:
  # the log says it happened, naming nobody, and the owner's own page (Settings,
  # You) says which verified email it was, and when.
  def self.signed_in_as_owner(email)
    Rails.logger.warn "A different verified email signed in as the install's owner"
    owner.tap { it.ahoy_events.create!(name: OWNER_SIGN_IN, properties: { email: email.to_s.downcase }, time: Time.current) }
  end
  private_class_method :signed_in_as_owner

  OWNER_SIGN_IN = "Signed in as the owner"

  # The latest sign-ins as them by another verified email, for their page.
  def sign_ins_as_owner = ahoy_events.where(name: OWNER_SIGN_IN).order(time: :desc, id: :desc).limit(20)

  def self.claim_owner(sub, email)
    find_by(oidc_sub: "owner:#{email.to_s.downcase}")&.tap { it.update!(oidc_sub: sub) } # tenancy-ok: the row held for the owner's first sign-in
  end

  # Cloudflare Access keyed people "cloudflare-access:<verified email>". Their
  # first sign-in under another subject (Ajent's) takes that row over, so the
  # agents, conversations and connectors they made stay theirs: the id does not
  # change. Only that exact key, never a match by email alone, and a row that
  # already has the subject wins. Once everyone
  # Access made has signed in through Ajent once, this can go.
  def self.claim_access_user(sub, email)
    user = find_by(oidc_sub: "cloudflare-access:#{email.to_s.downcase}") # tenancy-ok: the one row Access made for this verified email
    user&.tap { it.update!(oidc_sub: sub) }
  end
  private_class_method :claim_access_user

  # A new agent is the install's starter (APP__STARTER_AGENT) under the name
  # the person gave it, its purpose, if they gave one, added to the starter's
  # instructions; it rewrites them itself when asked (Tool::ChangeYourself).
  # A new agent runs on the model and thinking level of the one the person
  # used last, which they know works for them (their subscription, say); the
  # starter's model only for their first, or when that model is gone.
  # Another agent's instructions (`instructions`) take the starter's place.
  def start_agent(name = nil, purpose: nil, instructions: nil, email_name: nil, title: nil, workspace: personal_workspace)
    starter = Agent.starter(DurableAssistants.config(:app, :starter_agent))
    if (last = model_source)
      starter = starter.merge(model: last.model, thinking_level: last.thinking_level)
    end
    # Only the starter leaves the name out; a blank one the person typed is refused.
    name ||= starter[:name]
    # The starter's instructions say {{name}} where the agent's own name goes, so a new agent is not told it is the starter.
    instructions ||= starter[:instructions].gsub("{{name}}", name.to_s)
    instructions = "#{instructions}\n\n## Your purpose\n\n#{purpose.strip}" if purpose.present?
    workspace.agents.create!(starter.merge(user: self, name: name, instructions: instructions, email_name: email_name, title: title))
  end

  # "New agent from here": a whole new agent (its own name, address, computer
  # and bot), made as start_agent makes one, that carries on from another's
  # reply. It takes that agent's instructions, skills and notes, and its
  # thread starts as a copy of the other's up to the reply. Its tools,
  # connectors and model are a new agent's: the person set those for the
  # other agent's work. Made whole or not at all: a sidecar that cannot fork
  # leaves no agent behind, and the error goes on to the caller.
  def start_agent_from(message, name:, request_id:, purpose: nil, email_name: nil, title: nil)
    source = message.conversation.agent
    workspace = source.workspace
    transaction do
      # The other agent's instructions name it; the new one is told its own name instead.
      instructions = name.present? ? source.instructions.gsub(source.name, name) : source.instructions
      start_agent(name, purpose: purpose, instructions: instructions, email_name: email_name, title: title, workspace: workspace).tap do |agent|
        source.skills.each { it.copy_to(agent).save! }
        agent.notes.create!(source.notes.map { it.slice(:key, :body) })
        message.conversation.fork_into(agent.conversation, at: message, request_id: request_id)
      end
    end
  end

  # The starter is one agent: once someone has it, a later person starts with
  # none and makes their own with New agent, rather than a numbered copy
  # (Assistant 2, at assistant-2@) that could never be renamed.
  def start_starter
    start_agent unless Agent.taken?(Agent.starter(DurableAssistants.config(:app, :starter_agent))[:name])
  end

  # Their own workspace, which they own. A person the migrations did not see
  # (one an older release signed in during a deploy) gets it here, when first needed.
  def personal_workspace
    super || with_lock { reload_personal_workspace || memberships.create!(workspace: Workspace.new(personal: true), role: "owner").workspace }
  end

  # Signed in with their email verified, they join every workspace it was
  # invited to. The last one joined, if any, is where they start. Not in an
  # install that serves one person, where whoever signs in is its owner.
  def accept_invitations
    return if Admission.owner
    Workspace::Invitation.approved.where(email: email.to_s.downcase).map { it.tap { it.accept(self) }.workspace }.last # tenancy-ok: the invitations to the email the person just verified
  end

  # The install's connectors each of their workspaces turned on, in line with
  # the install, their personal one made first if they have none yet (McpServer.install_for).
  def install_connectors = (workspaces.to_a | [ personal_workspace ]).each { McpServer.install_for(it) }

  # The workspace a request works in: the one its session names while they
  # still belong to it, and their personal one otherwise, so someone removed
  # from a workspace is out of it on their next request.
  def workspace_for(id) = (workspaces.find_by(id: id) if id) || personal_workspace

  # The agent whose thread moved last, if its model is still offered.
  def model_source
    agents.joins(:conversation).order("conversations.last_message_at": :desc, id: :desc).first
      .then { it if it&.model.in?(Agent.models) }
  end

  # Every card waiting on this person, in each of their workspaces, since a
  # notice from any of them reaches their phone and Watch. Needs you lists
  # them and the badge counts them, so the two never disagree.
  def needs_you = invocations.includes(conversation: { agent: :workspace }).waiting_on_person

  def needs_you_count = needs_you.size

  # The same cards by the workspace each waits in, for what shows every
  # workspace apart (the agents list, Workspaces › Overview), so a group's
  # count and the badge never disagree either.
  def needs_you_by_workspace = needs_you.group_by { it.conversation.agent.workspace_id }

  def admin? = Admission.admin?(email)

  # The office's owner (OFFICE__OWNER_EMAIL): only their workspaces use the
  # office connectors' shared keys (McpServer.install_for), and only they turn
  # one on in another's workspace they are in. Nobody when none is set, admins
  # included: the keys reach what they reach (a CRM, say) for one person.
  # Not ACCESS__OWNER_EMAIL (Admission.owner), which signs everyone in as one
  # person; naming the office's owner must not make an install that.
  def install_owner?
    office_owner = DurableAssistants.config(:office, :owner_email).to_s.strip.downcase
    office_owner.present? && email.to_s.strip.downcase == office_owner
  end

  # What the app calls the person: their name, or, until they have one, their email's part before the @. Some
  # identity providers send the email as the name; that is no name.
  def to_s = named? ? name : email.to_s.split("@").first.presence || email.to_s

  # A name, not an email in its place. Once there is one, sign-in leaves it alone, so the name a person sets in
  # Settings outlasts the provider's.
  def named? = name.present? && !name.include?("@")

  # Whether a channel that knows people only by the name they show (Campfire,
  # Telegram) names this person. Anyone may show any name, so it decides only
  # when a message is read, as "urgent" does, never what it may do (#85).
  def goes_by?(shown) = named? && shown.to_s.squish.casecmp?(name.squish)
end
