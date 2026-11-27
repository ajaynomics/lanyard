# Gmail sign-in identifies the mailbox; only the workspace owner opts in
# to copying it into the agent's thread.
class Agent::GmailInbox < ApplicationRecord
  self.table_name = "agent_gmail_inboxes"

  belongs_to :agent
  belongs_to :mcp_server
  belongs_to :enabled_by, class_name: "User"
  has_many :receipts, dependent: :delete_all

  normalizes :mailbox, with: -> { it.strip.downcase.presence }
  validates :mailbox, presence: true
  validate :connector_in_workspace

  scope :enabled, -> { where(enabled: true) }

  def self.owner_at_sign_in?(agent, person, verified_email)
    person && person.email.present? && person.email.casecmp?(verified_email.to_s) &&
      agent.workspace.memberships.owner.exists?(user_id: person.id)
  end

  def self.supports?(connector) = connector&.google == :gmail && !connector.gmail_grant? && !connector.authorized_by_header?

  def self.connectors_for(workspace) = workspace.mcp_servers.select { supports?(it) }

  def activate(connector:, by:, verified_email:, mailbox:)
    return false unless self.class.owner_at_sign_in?(agent, by, verified_email)
    connector = agent.workspace.mcp_servers.find(connector.id)
    return false unless self.class.supports?(connector)

    mailbox = self.class.normalize_value_for(:mailbox, mailbox)
    unless mailbox
      errors.add(:base, "Enter the Gmail address you want to copy from.")
      return false
    end

    profile = McpServer::Google.new(connector).read_gmail_inbox { it.profile }
    unless profile.email == mailbox
      errors.add(:base, "The connector's Gmail account must match the mailbox you entered.")
      return false
    end

    # Check again after the Google request; the workspace may have changed hands.
    agent.workspace.with_lock do
      return false unless self.class.owner_at_sign_in?(agent, by.reload, verified_email)
      reload if persisted?
      return true if enabled? && mcp_server_id == connector.id && enabled_by_id == by.id && self.mailbox == mailbox

      update(mcp_server: connector, enabled_by: by, mailbox: mailbox, history_id: profile.history_id, enabled: true, paused_reason: nil)
    end
  rescue McpServer::SignInNeeded
    reload if persisted?
    errors.add(:base, "Sign in to this Gmail connector before turning on its inbox.")
    false
  rescue DurableAssistants::Google::Error
    errors.add(:base, "Could not verify this Gmail connector. Try again.")
    false
  end

  def pause!(reason = nil)
    assign_attributes(enabled: false, paused_reason: reason)
    save!(validate: false)
  end

  def connector
    candidate = agent.workspace.mcp_servers.find_by(id: mcp_server_id)
    candidate if self.class.supports?(candidate)
  end

  def current_permission?
    agent.workspace.gmail_inboxes.enabled.exists?(id: id, lock_version: lock_version)
  end

  def enabled_by_owner?
    agent.workspace.memberships.owner.exists?(user_id: enabled_by_id)
  end

  def fetch
    Agent::GmailInbox::Source.new(self, agent: agent, connector: connector).fetch if enabled?
  end

  private
    def connector_in_workspace
      errors.add(:mcp_server, "must be a Gmail connector in this workspace") unless connector
    end
end
