# Hands a shared workspace to one of its members, removes a member or cancels
# an invitation, as its members page does (Workspace::Membership). What
# people may reach changes, so its owner allows every one, even where the
# install approves everything.
class Tool::ChangeWorkspaceMember < Tool
  include Tool::WorkspaceCalls

  CHANGES = %w[ remove make_owner ].freeze

  description "Change who is in a shared workspace your person owns, when they ask: \"remove\" a member, or cancel " \
    "the invitation of someone invited, or \"make_owner\" to hand the workspace to a member, who then decides who is in it."
  argument :workspace, :string, required: false, max_length: 100, description: "Its name, as list_workspaces gives it. Left out, yours."
  argument :email, :string, min_length: 3, max_length: 254, description: "The member's or the invited person's email."
  argument :change, :string, enum: CHANGES
  asks :approval, even_approving_everything: true

  def approval_title(arguments)
    where = arguments["workspace"].presence || agent.workspace
    arguments["change"] == "make_owner" ? "Make #{arguments["email"]} the owner of #{where}?" : "Remove #{arguments["email"]} from #{where}?"
  end

  def approval_note(_arguments) = "Only #{person}, its owner, can allow it."

  def call(email:, change:, workspace: nil)
    found = check
    if found.is_a?(Workspace::Invitation)
      found.destroy!
      { cancelled: found.email }
    elsif change == "make_owner"
      found.take_ownership
      { owner: found.user.to_s }
    else
      found.destroy!
      { removed: found.user.to_s }
    end
  end

  private
    # The membership or invitation it changes.
    def check
      workspace = owned_workspace_named(arguments["workspace"], to: "change who is in it")
      email, change = arguments.values_at("email", "change")
      membership = workspace.memberships.joins(:user).find_by("lower(users.email) = ?", email.to_s.strip.downcase)
      invitation = workspace.invitations.find_by(email: email.to_s.strip.downcase)
      if membership&.owner? then raise Tool::Refusal, "#{membership.user} owns #{workspace}; nobody removes its owner."
      elsif membership then membership
      elsif invitation && change == "remove" then invitation
      else raise Tool::Refusal, "#{email} is not #{change == "remove" ? "in or invited to" : "a member of"} #{workspace}."
      end
    end
end
