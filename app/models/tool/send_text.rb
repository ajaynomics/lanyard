# Sends a text from the agent's own number (docs/phone.md). The app picks the
# number; the model names only whom to text and what to say. Each text asks the
# person first unless they allowed it "Always", for everyone or for that number,
# as with email. Past DAILY_LIMIT texts in a day the tool refuses, and the person
# is told once: an agent texting that much is more likely stuck than busy.
class Tool::SendText < Tool
  DAILY_LIMIT = 20
  LIMITED = "You have sent #{DAILY_LIMIT} texts in the last 24 hours, the most allowed."

  description "Send a text message from your own phone number to one North American number. " \
    "Up to 160 characters goes as one text; longer goes as one MMS. Each text waits for the person's approval " \
    "unless they allowed it always. At most #{DAILY_LIMIT} texts in any 24 hours."
  argument :to, :string, pattern: "^[2-9][0-9]{2}[2-9][0-9]{6}$", description: "Ten digits, no spaces or +1, as 6475550123."
  argument :body, :string, min_length: 1, max_length: DurableAssistants::Voipms::MMS_LIMIT
  asks :approval
  reaches_others
  effect :external

  def permitted? = agent.texts?

  def recipients = [ invocation.arguments["to"] ]

  def call(to:, body:)
    if today.where(state: %w[ running succeeded ]).count >= DAILY_LIMIT
      tell_person unless today.where(state: "failed").where("error LIKE ?", "#{LIMITED}%").exists?
      raise Refusal, "#{LIMITED} Tell your person here what you meant to send."
    end
    id = DurableAssistants::Voipms.send_text(from: agent.phone_number, to: to, body: body)
    { sent: to, from: agent.phone_number, id: id }
  rescue DurableAssistants::Voipms::Error => error
    raise Refusal, error.message
  end

  private
    # Its texts from any of its threads in the last day, this one not counted.
    def today
      agent.invocations.where(tool_name: self.class.tool_name, created_at: 1.day.ago..).where.not(id: invocation.id)
    end

    # Told once, at the first refusal in a day, however often it tries.
    def tell_person
      return unless Push.configured? && user.push_subscriptions.exists?
      Push::DeliveryJob.perform_later(user, { kind: "texts", title: "#{agent.name} stopped texting",
        body: "#{agent.name} reached #{DAILY_LIMIT} texts in a day, so I've paused its texts. It can send again as those pass 24 hours.",
        url: Rails.application.routes.url_helpers.conversation_path(conversation), tag: "texts-limit-#{agent.id}", badge: user.agents_needing_you })
    end
end
