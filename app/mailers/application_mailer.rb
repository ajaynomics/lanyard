class ApplicationMailer < ActionMailer::Base
  default from: -> { DurableAssistants.config(:app, :mailer_from) }
  layout "mailer"
end
