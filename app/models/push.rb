# Web Push: a short notice to the devices where a person turned notifications
# on (Push::Subscription), when an agent needs them or has finished a reply
# (Conversation::Notifiable). The install's VAPID keys sign each one
# (config/web_push.yml); without them push is off and Settings does not
# offer it.
module Push
  def self.table_name_prefix = "push_"

  def self.configured? = vapid.values_at(:public_key, :private_key, :subject).all?(&:present?)

  def self.public_key = DurableAssistants.config(:web_push, :public_key)

  def self.vapid
    { public_key: public_key, private_key: DurableAssistants.config(:web_push, :private_key),
      subject: DurableAssistants.config(:web_push, :subject) }
  end
end
