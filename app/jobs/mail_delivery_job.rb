# Action Mailer's own delivery job, with its arguments kept out of the log:
# they are what the mail says (ApplicationMailer.delivery_job).
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  self.log_arguments = false
end
