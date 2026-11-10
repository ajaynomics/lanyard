class ApplicationMailer < ActionMailer::Base
  default from: -> { DurableAssistants.config(:app, :mailer_from) }
  layout "mailer"
  # deliver_later queues a mail's own arguments (a card's title, a message);
  # this job keeps them out of the log.
  self.delivery_job = MailDeliveryJob
end
