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

  # Each kind of notice, by the choice in Settings that lets it through.
  CHOICES = { "reply" => :push_messages, "needs_you" => :push_needs_you, "held" => :push_needs_you,
              "error" => :push_errors, "texts" => :push_errors }.freeze

  # The one way a notice leaves: to the person's devices, if they have any
  # and want this kind, out of the request or frame that caused it. A notice
  # is { title, body, url, tag }; its kind and the badge's count are added.
  def self.deliver(user, kind:, **notice)
    return unless configured? && user.public_send(CHOICES.fetch(kind)) && user.push_subscriptions.exists?
    Push::DeliveryJob.perform_later(user, { kind: kind, **notice, badge: user.agents_needing_you })
  end

  def self.public_key = DurableAssistants.config(:web_push, :public_key)

  def self.vapid
    { public_key: public_key, private_key: DurableAssistants.config(:web_push, :private_key),
      subject: DurableAssistants.config(:web_push, :subject) }
  end
end
