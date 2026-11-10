# Web Push: a short notice to the devices where a person turned notifications
# on (Push::Subscription), when an agent needs them or has finished a reply
# (Conversation::Notifiable). The install's VAPID keys sign each one
# (config/web_push.yml); without them, or with a subject a push service
# would refuse, push is off and Settings says it is not available.
module Push
  def self.table_name_prefix = "push_"

  # How the push services reach whoever runs the install. Apple refuses a push
  # signed with anything but a mailto: or https: address.
  SUBJECT = %r{\A(mailto:[^\s<>@]+@[^\s<>@]+|https://\S+)\z}

  def self.configured? = vapid.values_at(:public_key, :private_key).all?(&:present?) && vapid[:subject].to_s.match?(SUBJECT)

  def self.public_key = DurableAssistants.config(:web_push, :public_key)

  def self.vapid
    { public_key: public_key, private_key: DurableAssistants.config(:web_push, :private_key),
      subject: DurableAssistants.config(:web_push, :subject) }
  end
end
