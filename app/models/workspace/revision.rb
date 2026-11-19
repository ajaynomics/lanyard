# A kept copy of a workspace's shared instructions as one change left them:
# who made the change (its owner) and who proposed it, a member or an agent.
# Someone deleted since is forgotten, the copy kept.
class Workspace::Revision < ApplicationRecord
  belongs_to :workspace
  belongs_to :changed_by, class_name: "User", optional: true
  belongs_to :proposed_by, class_name: "User", optional: true
  belongs_to :proposed_by_agent, class_name: "Agent", optional: true

  def proposer = proposed_by_agent || proposed_by
end
