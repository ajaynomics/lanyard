# Who answers an outside contact in a workspace: mail or a text from them to
# any of its agents reaches this agent alone (ReceivedMail#deliver_to). Only
# the workspace's owner keeps the list.
class Workspace::ContactRoute < ApplicationRecord
  belongs_to :workspace
  belongs_to :agent

  normalizes :contact, with: -> { Workspace::Contact.normalize(it) || it.strip }

  validates :contact, uniqueness: { scope: :workspace, message: "is already routed" }
  validate :contact_is_one, :agent_in_workspace

  def to_s = Workspace::Contact.label(contact)

  private
    def contact_is_one
      errors.add(:contact, "should be an email address or a ten-digit North American number") unless Workspace::Contact.normalize(contact) == contact
    end

    def agent_in_workspace
      errors.add(:agent, "must be one of #{workspace}'s agents") if agent && agent.workspace_id != workspace_id
    end
end
