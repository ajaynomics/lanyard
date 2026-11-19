# A person in a workspace. Its one owner invites and removes people;
# otherwise an owner and a member use the workspace alike.
#
# A member may name one of the workspace's agents as their only outbound
# contact (sole_contact): then no other agent of it sends to their address or
# number, nor mails them its cards (Tool#contact_refusal,
# Conversation::Notifiable). It binds this workspace's agents alone. The app
# knows a person by their email; the number they give here is how it knows
# their texts.
class Workspace::Membership < ApplicationRecord
  belongs_to :workspace
  belongs_to :user
  belongs_to :sole_contact, class_name: "Agent", optional: true

  enum :role, %w[ owner member ].index_by(&:itself)

  normalizes :phone_number, with: -> { Workspace::Contact.normalize(it) || it.strip.presence }

  validates :user, uniqueness: { scope: :workspace }
  validates :role, uniqueness: { scope: :workspace, message: "is taken: a workspace has one owner" }, if: :owner?
  validates :phone_number, format: { with: /\A\d{10}\z/, message: "should be a ten-digit North American number" }, allow_nil: true
  validate :sole_contact_in_workspace

  # The owner removes a member, and a member may leave; nobody removes the owner.
  def removable_by?(person) = member? && (person == user || person == workspace.owner)

  # Leaving would end their way into the install: not on its list, in no
  # other shared workspace and invited to none (Admission).
  def only_way_in?
    !Admission.listed?(user.email) && !user.workspaces.shared.where.not(id: workspace_id).exists? &&
      !Workspace::Invitation.approved.exists?(email: user.email.to_s.downcase) # tenancy-ok: whether any workspace still lets this person's email in
  end

  # The workspace's one owner becomes a member, and this person its owner. One
  # at a time, as its one-owner index asks.
  def take_ownership
    transaction do
      workspace.memberships.owner.where.not(id: id).each { it.update!(role: "member") }
      update!(role: "owner")
    end
  end

  # An "Always" lets the workspace's agents act unasked on the word of the
  # person who gave it, so it goes with them, in the same transaction (#40, decision 2).
  after_destroy { workspace.permissions.where(granted_by: user).destroy_all }

  # Their address and number, as Workspace::Contact compares them.
  def contacts = Workspace::Contact.all([ user.email, phone_number ])

  # Whether this agent of the workspace may reach them by address or number.
  def hears_from?(agent) = sole_contact_id.nil? || sole_contact_id == agent.id

  # What an agent told no is told: whom to go through.
  def refusal = "#{user} hears only from #{sole_contact} in #{workspace}, so nothing was sent. Go through #{sole_contact} instead."

  # A signed stream name never expires, so a removed person's open pages are
  # closed; on reconnecting, the workspace's lists refuse them (WorkspaceStreamsChannel).
  after_destroy_commit { ActionCable.server.remote_connections.where(current_user: user).disconnect }

  private
    def sole_contact_in_workspace
      errors.add(:sole_contact, "must be one of #{workspace}'s agents") if sole_contact && sole_contact.workspace_id != workspace_id
    end
end
