# An alarm on the agent's own calendar or task list, mailed to the agent's
# own address (AlarmMailerJob) from the install's do-not-reply address
# (MAIL__ALARMS_FROM), never its own: mail from its own address is not
# news and is dropped (AgentsMailbox, Agent::MailAccount::Inbox). It lands
# as any other mail does, untrusted, so an alarm's words grant nothing. Its
# Message-ID is the alarm's own, so the same alarm mailed twice reaches the
# thread once (ReceivedMail).
class AlarmMailer < ApplicationMailer
  layout false
  default from: -> { AlarmMailer.from }

  def self.from = DurableAssistants::Email.setting(:alarms_from).presence || DurableAssistants::Email.domain&.then { "no-reply@#{it}" }

  # Where it reads its own mail: its address here, or its own account's
  # where that is its only address.
  def self.address_of(agent) = agent.mail_primary? ? agent.mail_account.address : agent.email_address

  def due(agent, alarm)
    headers["Message-ID"] = "<alarm.#{alarm.key}@#{domain}>"
    mail(to: self.class.address_of(agent), subject: alarm.title) { it.text { render plain: alarm.text } }
  end

  # Those that came due while nothing could read them, in one message.
  def missed(agent, alarms)
    headers["Message-ID"] = "<alarms.#{Digest::SHA256.hexdigest(alarms.map(&:key).join).first(32)}@#{domain}>"
    body = alarms.map { "#{Conversation.stamp(it.at, agent.time_zone)}: #{it.text}" }.join("\n\n---\n\n")
    mail(to: self.class.address_of(agent), subject: "#{alarms.size} missed #{"reminder".pluralize(alarms.size)}") { it.text { render plain: body } }
  end

  private
    def domain = Mail::Address.new(self.class.from).domain
end
