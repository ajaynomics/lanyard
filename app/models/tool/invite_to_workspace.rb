# Invites an email to a shared workspace, as its page's Invite does
# (Workspace#invite): the install's admins still say who comes in. It lets
# someone into the workspace's agents and threads, so its owner allows every
# one, even where the install approves everything.
class Tool::InviteToWorkspace < Tool
  include Tool::WorkspaceCalls

  description "Invite someone by email to a shared workspace your person owns, when they ask. Once the install's " \
    "admin approves, they can sign in and reach its agents and threads; someone already here joins at once."
  argument :workspace, :string, required: false, max_length: 100, description: "Its name, as list_workspaces gives it. Left out, yours."
  argument :email, :string, min_length: 3, max_length: 254
  asks :approval, even_approving_everything: true

  def approval_title(arguments) = "Invite #{arguments["email"]} to #{arguments["workspace"].presence || agent.workspace}?"
  def approval_note(_arguments) = "They would reach its agents, their threads and its connectors. Only #{person}, its owner, can allow it."

  def call(email:, workspace: nil)
    invitation = check.invite(email, by: person)
    refuse_unless_saved(invitation) unless invitation.accepted?
    if invitation.accepted? then { added: invitation.invitee.to_s }
    elsif invitation.awaiting_approval? then { invited: invitation.email, waits_for_an_admin: true }
    else { invited: invitation.email }
    end
  end

  private
    def check = owned_workspace_named(arguments["workspace"], to: "invite")
end
