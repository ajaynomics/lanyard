# Tells an invited email that it may now sign in, and where the workspace is.
# Where the workspace has its own mail domain, it comes from there, through
# that domain's server, as its agents' notices do (Workspace::MailDomain); a
# vault that can't be read then is tried again (MailDeliveryJob), never sent
# the install's way.
class WorkspaceMailer < ApplicationMailer
  def invitation(invitation)
    @invitation = invitation
    @url = workspace_url(invitation.workspace, **invitation.workspace.brand.url_options)
    domain = invitation.workspace.mail_domain
    mail to: invitation.email, subject: "#{invitation.inviter} invited you to #{invitation.workspace}",
      **{ from: domain&.app_from, delivery_method_options: domain&.delivery_options }.compact
  end
end
