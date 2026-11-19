# Web Push: a short notice to the devices where a person turned notifications
# on (Push::Subscription), when an agent needs them or has finished a reply
# (Conversation::Notifiable). The phone app's notifications go the same way,
# through Apple's push service instead (Push::Device). The install's VAPID keys sign each one
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

  # How a notice arrives (#82). Priority is what needs the person now, a card
  # waiting on them: it sounds, reaches the Watch, and breaks through a Focus
  # as time-sensitive. Everything else is regular: quiet, grouped by thread.
  # The owner of the agent's workspace may lower its notices to regular
  # (Agent#priority_notifications); nothing raises a regular kind.
  PRIORITY_KINDS = %w[ needs_you ].freeze

  def self.level(kind, agent)
    kind.in?(PRIORITY_KINDS) && (agent.nil? || agent.priority_notifications?) ? "priority" : "regular"
  end

  # The phone app's own notifications go through Apple's push service
  # (Push::Device), on only where the install has an APNs key.
  def self.native? = DurableAssistants::Apns.configured?

  # Whether a notice could reach the person at all: a browser with Web Push,
  # or the phone app with Apple's.
  def self.reaches?(user)
    (configured? && user.push_subscriptions.exists?) || (native? && user.push_devices.exists?)
  end

  # The one way a notice leaves: to the person's devices, if they have any
  # and want this kind, out of the request or frame that caused it. A notice
  # is { title, body, url, tag }, and approval_url where a tap on the phone
  # should open the card itself; its kind, its level, from the agent it is
  # from where there is one, and the badge's count are added.
  def self.deliver(user, kind:, agent: nil, **notice)
    return unless user.public_send(CHOICES.fetch(kind)) && reaches?(user)
    Push::DeliveryJob.perform_later(user, { kind: kind, level: level(kind, agent), **notice, badge: user.needs_you_count })
  end

  def self.public_key = DurableAssistants.config(:web_push, :public_key)

  def self.vapid
    { public_key: public_key, private_key: DurableAssistants.config(:web_push, :private_key),
      subject: DurableAssistants.config(:web_push, :subject) }
  end
end
