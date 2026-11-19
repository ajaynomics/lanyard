# A new shared workspace, as New workspace makes one (Workspace.make), owned
# by the person the agent works for. Nobody else is in it until she invites them.
class Tool::MakeWorkspace < Tool
  include Tool::WorkspaceCalls

  description "Make a new shared workspace for your person, when they ask: a place of its own for a team, a client " \
    "or a household, with its own agents, connectors and people. They own it, and invite people with invite_to_workspace."
  argument :name, :string, min_length: 1, max_length: 100
  asks :approval, always: false

  def approval_title(arguments) = "Make a workspace called #{arguments["name"].to_s.squish}, owned by #{person}?"

  def call(name:)
    workspace = Workspace.make(name: name.squish, owner: person)
    refuse_unless_saved(workspace)
    { made: workspace.name, owner: person.to_s }
  end
end
