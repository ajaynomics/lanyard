# Action Mailer's own delivery job, with its arguments kept out of the log:
# they are what the mail says (ApplicationMailer.delivery_job).
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  self.log_arguments = false

  # A workspace's own mail server whose saved sign-in can't be read now (the
  # vault down) is tried again, so a notice still arrives (AgentMailer#needs_you).
  retry_on Workspace::MailDomain::SignInError, wait: 5.minutes, attempts: 12
end
