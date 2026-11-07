# The install's mail settings for a test, at a domain nobody owns. Mail goes
# to Action Mailer's test deliveries; nothing is sent.
module EmailTestHelper
  MAIL = { domain: "agents.example", smtp_address: "smtp.agents.example", imap_address: "imap.agents.example",
           imap_port: 993, imap_user_name: "catchall", imap_password: "synthetic" }.freeze

  def install_email_settings
    settings = Rails.application.config.x.mail
    @previous_mail = settings.dup
    settings.merge!(MAIL)
  end

  def remove_email_settings
    Rails.application.config.x.mail.replace(@previous_mail) if @previous_mail
  end
end
