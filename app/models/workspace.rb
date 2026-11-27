# The boundary for everything an agent can reach (docs/design/workspaces.md).
# Every agent belongs to one. Each person has a personal one, which they own;
# a shared one has a name, one owner and any number of members, who all reach
# its agents and threads alike.
class Workspace < ApplicationRecord
  include SizesComputers
  include VaultUser
  include SharedInstructions
  include ToolSwitches

  has_many :memberships, dependent: :destroy
  has_many :invitations, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_one :owner_membership, -> { owner }, class_name: "Workspace::Membership"
  has_one :owner, through: :owner_membership, source: :user
  has_many :agents, dependent: :restrict_with_exception
  has_many :agent_setups, dependent: :restrict_with_exception
  has_many :conversations, through: :agents, source: :conversations
  has_many :payment_requests, through: :conversations
  has_many :invocations, through: :conversations
  has_many :messages, through: :conversations
  has_many :helpers, through: :conversations
  has_many :workflow_runs, through: :conversations
  has_many :permissions, through: :agents
  has_many :gmail_inboxes, through: :agents
  # Its connectors: for all its agents, and each conversation's own (Conversation#connectors).
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy
  # Whose model account its agents' calls are billed to (docs/billing.md):
  # none, the install's, as before workspaces chose; itself; or another
  # workspace, which only someone who owns both chooses (Workspaces::PayersController).
  belongs_to :payer, class_name: "Workspace", optional: true
  # What its agents' calls used, whoever paid; never what another's used, even one it pays for.
  has_many :model_usages, dependent: :delete_all
  has_many :pilot_budgets, through: :agents
  # Its own address and key for an install connector. Its connector goes with the workspace, so nothing is left to follow.
  has_many :install_connectors, dependent: :delete_all
  # The install it came from, when it came in whole (docs/import.md).
  has_one :import, dependent: :destroy
  has_many :concourse_agents, through: :agents
  # Its Campfire rooms' loop holds.
  has_many :campfire_rooms, dependent: :delete_all
  # Who answers which outside contact (Workspace::ContactRoute).
  has_many :contact_routes, -> { order(:contact) }, dependent: :delete_all
  # Its own mail domain, server and catch-all box, which the install's
  # operator sets (Workspace::MailDomain); none, the install's.
  has_one :mail_domain, dependent: :delete

  # Its Concourse home network, where a join is ordinary; elsewhere an identity
  # is a bridge its owner approves (ConcourseAgent::Bridge). None, as before
  # workspaces had one: every join is ordinary.
  normalizes :concourse_home, with: -> { it.strip.presence }
  validates :concourse_home, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/, message: "must be an organization's name on Concourse, such as acme" }, allow_nil: true

  # Its own Campfire (docs/campfire.md, "A workspace's own Campfire"), and the
  # vault entry its administrator signs in with; none, the install's.
  normalizes :campfire_url, with: -> { it.strip.delete_suffix("/").presence }
  normalizes :campfire_vault_entry, with: -> { it.squish.presence }
  validates :campfire_url, format: { with: %r{\Ahttps?://[^\s/]+(/\S*)?\z}, message: "must be an address like https://chat.example.com" }, allow_nil: true
  validates :campfire_vault_entry, length: { maximum: 200 }

  # The vault entry of its own voip.ms account, which its agents text through
  # (docs/phone.md, "A workspace's own voip.ms account"); none, the install's.
  normalizes :voipms_vault_entry, with: -> { it.squish.presence }
  validates :voipms_vault_entry, length: { maximum: 200 }

  # Its owner's approval policy; none, the install's (Workspace::ApprovalPolicy).
  normalizes :approval_policy, with: -> { it.presence }
  validates :approval_policy, inclusion: { in: ApprovalPolicy::CHOICES.keys }, allow_nil: true

  # Its own name, colour and link host (Brand). Its owner sets the name and
  # colour, on its page; the name stays short enough for the header. Only the
  # install's operator sets the host, in a console: it must be one the
  # install answers on.
  APP_NAME_LIMIT = 40
  normalizes :app_name, with: -> { it.squish.presence }
  normalizes :link_host, with: -> { it.strip.downcase.delete_suffix(".").presence }
  validates :app_name, length: { maximum: APP_NAME_LIMIT }
  validates :accent_hue, numericality: { only_integer: true, in: 0..360, message: "must be a hue from 0 to 360" }, allow_nil: true
  validates :link_host, inclusion: { in: ->(_) { DurableAssistants.public_hosts }, message: "must be a name this install answers on: APP__URL's or one of APP__REDIRECTS" }, allow_nil: true

  scope :shared, -> { where(personal: false) }
  # As the agents list groups them: the person's own first, then the shared ones by name.
  scope :personal_first, -> { order(personal: :desc, name: :asc, id: :asc) }

  # A personal one may be blank, going by its person's name; neither is longer than the form allows.
  validates :name, presence: true, unless: :personal?
  validates :name, length: { maximum: 100 }

  # Its agents' Sprites, unless an agent sets its own (Computer#size).
  sizes_computers cpus: :computer_cpus, memory_mib: :computer_memory_mib, disk_mib: :computer_disk_mib

  # A shared workspace, named, which its maker owns: from New workspace, or an agent's make_workspace.
  def self.make(name:, owner:)
    new(name: name).tap do |workspace|
      workspace.memberships.build(user: owner, role: "owner")
      workspace.save
    end
  end

  # An email a shared workspace lets in: one invited to it with an admin's yes, or a member's.
  def self.admits?(email)
    Invitation.approved.exists?(email: email) || shared.joins(:members).exists?(users: { email: email }) # tenancy-ok: admission asks of every workspace
  end

  def member?(user) = memberships.exists?(user: user)

  def broadcast_reporting_tree
    Turbo::StreamsChannel.broadcast_update_to [ self, :conversations ],
      target: ActionView::RecordIdentifier.dom_id(self, :tree_revision), partial: "conversations/tree_revision"
  end

  # Whether this person may invite people into it: its owner, when it is shared,
  # on an install that lets more than one person in (Invitation refuses the rest).
  # Its invite form and the agents list's Invite people… both ask it, so the two
  # never disagree; the list's loaded memberships answer without a query per group.
  def invites_from?(person)
    !personal? && !Admission.owner && memberships.any? { it.user_id == person.id && it.owner? }
  end

  # Its owner invites an email, from its page or through an agent. An admin's
  # invitation (`admin`) is approved as it is made; someone the install
  # already lets in, or an admin's invitee who has signed in before, joins at
  # once, and the invitation, accepted, is gone.
  def invite(email, by:, admin: by.admin?)
    invitations.new(email: email, inviter: by).tap do |invitation|
      next unless invitation.save
      if (person = invitation.invitee) && (admin || Admission.admits?(person.email))
        invitation.accept(person)
      elsif admin
        invitation.approve(by: by)
      end
    end
  end

  # How its agents' calls that ask for approval are treated (Agent#allows?).
  def approvals = ApprovalPolicy.of(self)

  def asks_own_instruction_change?
    own_instruction_approval.nil? ? DurableAssistants.own_instruction_approval != false : own_instruction_approval
  end

  # What its agents' Sprites are made with when an agent sets none of its own.
  def computer_size = Computer::Size.resolve(own_size)

  # The install's connectors as this workspace has them: its own address and
  # key where it set them, otherwise the install's, whose key only a workspace
  # the install's owner owns may use (McpServer.install_for, #168).
  def install_entries
    own = install_connectors.index_by(&:name)
    McpServer.install_entries.to_h do |name, entry|
      [ name, own[name]&.over(entry) || (installs_keys? ? entry : entry.except(:api_key)) ]
    end
  end

  # The install's own keys are its owner's: a person who isn't must not reach
  # what that key reaches (a CRM, say) through a workspace of their own.
  def installs_keys? = owner&.install_owner? == true

  # One of the install's connectors with no install key at all (each agent acting
  # as itself, say), here, where the install's owner doesn't own it: nothing is
  # kept from the workspace, which has it once it has a key of its own (#241).
  def awaits_own_key?(name) = !installs_keys? && McpServer.install_entries.dig(name, :api_key).blank?

  # Turning one of the install's connectors on is its owner's choice, or the
  # install's owner's in a workspace they are in.
  def turns_on_install_connectors?(user) = user == owner || (user.install_owner? && member?(user))

  # Names the home network, or none. No identity that spoke stops: each one
  # outside the new home is a bridge, approved by whoever named it.
  def name_concourse_home(network, by:)
    speaking = concourse_agents.reject(&:waiting_for_owner?)
    transaction do
      update(concourse_home: network) or raise ActiveRecord::Rollback
      speaking.map(&:reload).each { it.approve_bridge(by) if it.waiting_for_owner? }
      true
    end || false
  end

  # Its own Campfire, its administrator read from the vault as `agent` when
  # needed; without one, the install's.
  def campfire(as:)
    return DurableAssistants::Campfire.install unless campfire_url
    DurableAssistants::Campfire::Site.new(campfire_url, (-> { campfire_sign_in(as) } if campfire_vault_entry))
  end

  # Its own voip.ms account, read from the vault as `agent` when a text is
  # sent or looked up; without one, nil: the install's.
  def voipms_account(as:) = (DurableAssistants::Voipms::Account.new(voipms_vault_entry, as) if voipms_vault_entry)

  # Whether its agents text through the same voip.ms account as `other`'s: the
  # install's for both, or one entry, named as the vault matches names.
  def same_voipms_account?(other) = voipms_vault_entry&.downcase == other.voipms_vault_entry&.downcase

  # The member this agent may not reach at any of these addresses or numbers:
  # one whose only contact here is another of its agents (Membership#sole_contact).
  def barred_member(agent, contacts)
    wanted = Workspace::Contact.all(contacts)
    return if wanted.empty?
    memberships.where.not(sole_contact_id: [ nil, agent.id ]).includes(:user, :sole_contact).find { it.contacts.intersect?(wanted) }
  end

  # The agent that answers this sender here, where the owner routed them.
  def answerer_for(sender) = Workspace::Contact.normalize(sender)&.then { contact_routes.find_by(contact: it)&.agent }

  # Where its agents' addresses are: its own domain, or the install's.
  def agents_mail_domain = mail_domain&.domain || DurableAssistants::Email.domain

  # Its agents have addresses at its own domain, or where the install has email.
  def agents_mail? = mail_domain.present? || DurableAssistants::Email.configured?

  def brand = Brand.new(self)

  # A personal workspace goes by its person's name.
  def to_s = name.presence || owner.to_s

  # Its name until a rename is saved, so a refused one is not shown as its name.
  def saved_name = name_was.presence || owner.to_s

  private
    # Read from the vault for each sign-in, never kept. The entry must be saved
    # for this Campfire's host, as a mail account's is for its server, so a
    # sign-in for another site never goes there.
    def campfire_sign_in(agent)
      entry = DurableAssistants::Passbolt.sign_in_by_name(agent, campfire_vault_entry)
      host = URI(campfire_url).host
      raise DurableAssistants::Campfire::Error, "#{campfire_vault_entry} is saved for #{entry.host || "no address"}, not #{host}, so it is not sent there." unless entry.host == host
      raise DurableAssistants::Campfire::Error, "#{campfire_vault_entry} has no email and password saved." if entry.username.blank? || entry.password.blank?
      [ entry.username, entry.password ]
    rescue DurableAssistants::Passbolt::Error => error
      raise DurableAssistants::Campfire::Error, error.message
    end
end
