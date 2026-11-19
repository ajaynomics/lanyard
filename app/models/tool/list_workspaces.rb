# The workspaces an agent may name (Tool::WorkspaceCalls): who is in each,
# its agents, and, where only its owner reads the answer, who is invited.
class Tool::ListWorkspaces < Tool
  include Tool::WorkspaceCalls

  description "List the workspaces you can name: their people and roles, and their agents. In your person's own " \
    "workspace that is every workspace of theirs; in a shared one, that one alone."

  def approver = nil

  def call = { workspaces: nameable.map { listing(it) } }

  private
    def listing(workspace)
      { name: workspace.to_s, yours: workspace.personal?, here: workspace == agent.workspace,
        members: workspace.memberships.includes(:user).order(:id).map { { name: it.user.to_s, email: it.user.email, role: it.role } },
        invited: (workspace.invitations.order(:email).pluck(:email) if agent.workspace.personal? && workspace.owner == person),
        agents: workspace.agents.order(:name).pluck(:name) }.compact
    end
end
