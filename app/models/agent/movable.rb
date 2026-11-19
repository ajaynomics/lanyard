# An agent moves to another workspace (docs/design/workspaces.md, section 1):
# an explicit act, by the owner of the workspace it is in, to one she is in,
# and logged. The same on its Move page and through move_agent.
#
# What is its own goes with it: its thread and history, notes, documents,
# skills, routines, computer, address, number, mail accounts, calendars and
# bots, and its thread's own connectors. What was the old workspace's stays:
# its connectors, which the agent no longer carries; the outside contacts it
# routed to the agent; a member's choice of it as their only contact. Anyone
# not in the new workspace takes back their "Always", as a removed member
# does. A Concourse identity is judged against the new workspace's home
# network, a bridge waiting for its owner. A Campfire bot stays on a Campfire
# both workspaces use, forgetting the old one's rooms, and otherwise is
# removed there and made anew on the new one's.
module Agent::Movable
  extend ActiveSupport::Concern

  def movable_by?(person) = owned_by?(person)

  # Where this person may move it: their other workspaces.
  def destinations_for(person) = person.workspaces.where.not(id: workspace_id).personal_first

  def move_to(destination, by:)
    errors.clear
    if (problem = move_refusal(destination, by:))
      errors.add(:base, problem)
      return false
    end
    from = workspace
    leaving_campfire = campfire_bot.present? && destination.campfire_url != from.campfire_url
    # While it is still the old workspace's, so its removal goes to the Campfire it is on.
    campfire_bot.destroy! if leaving_campfire
    transaction do
      core_connectors.delete_all
      connector_moves.delete_all
      update!(workspace: destination)
      conversations.each { it.mcp_servers.update_all(workspace_id: destination.id) }
      from.contact_routes.where(agent: self).delete_all
      from.memberships.where(sole_contact: self).update_all(sole_contact_id: nil)
      permissions.where.not(granted_by: destination.members).delete_all
      campfire_bot.update!(rooms: {}) if campfire_bot && !leaving_campfire
      concourse_agents.each { it.approve_again(by) }
      carry_office_connectors
    end
    conversation&.broadcast_moved_from(from)
    CampfireBotJob.perform_later(self) if leaving_campfire && campfire.admin?
    Rails.logger.info "Agent #{id} moved from workspace #{from.id} to workspace #{destination.id} by user #{by.id}"
    true
  end

  # Why this person may not move it there, or nil.
  def move_refusal(destination, by:)
    if !movable_by?(by) then "Only #{workspace.owner}, who owns #{called(workspace)}, can move #{name}."
    elsif destination == workspace then "#{name} is in #{called(workspace)} already."
    elsif !destination.member?(by) then "#{by} isn't in #{called(destination)}, so #{name} can't go there."
    else mail_link
    end
  end

  private
    # Mail goes one step, within one workspace (Agent#mail_goes_one_step).
    def mail_link
      if (passing = mail_from_agents.first) then "#{passing} passes its mail to #{name}. Stop that first, then move it."
      elsif mail_to_agent then "#{name} passes its mail to #{mail_to_agent}. Stop that first, then move it."
      end
    end

    def called(workspace) = workspace.personal? ? "#{workspace.owner}'s workspace" : workspace.name
end
