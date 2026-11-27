class Tool::ChangePhoneNumberSettings < Tool
  FIELDS = %i[ sms_forward sms_email voicemail_email ].freeze

  description "Change SMS forwarding, SMS-to-email or voicemail email for your own voip.ms number. " \
    "Only include the settings you want to change. This always asks for approval and checks the result with voip.ms."
  argument :sms_forward, :string, required: false, max_length: 10, description: "Ten digits, or an empty string to turn forwarding off."
  argument :sms_email, :string, required: false, description: "One email address, or an empty string to turn SMS email off."
  argument :voicemail_email, :string, required: false, max_length: 255, description: "One or more email addresses separated by commas, or an empty string to clear."
  asks :approval, even_approving_everything: true
  effect :external

  def refusal = refusal_for(requested)

  def previews? = true
  def approval_title(_arguments) = "Change phone settings for #{invocation.preview&.dig("number") || agent.phone_number}?"
  def details(_arguments) = invocation.preview&.dig("changes")

  def preview
    plan = prepare(requested)
    changes = requested.to_h do |field, value|
      [ field, "#{display(plan.before.fetch(field))} → #{display(value)}" ]
    end
    # The approval is for these values on this number, mailbox and account.
    digest = Agent::Canonical.digest([ agent.workspace_id, agent.voipms_account&.vault_entry, plan.number, plan.mailbox, plan.before, requested ])
    # The worker writes the same snapshot it just checked against the card.
    @approved_plan = plan if invocation.running?
    { "digest" => digest, "number" => plan.number, "changes" => changes.stringify_keys }
  rescue Refusal, DurableAssistants::Voipms::Error => error
    { "error" => error.message }
  end

  def call(sms_forward: nil, sms_email: nil, voicemail_email: nil)
    (@approved_plan || prepare({ sms_forward:, sms_email:, voicemail_email: }.compact)).apply
  rescue DurableAssistants::Voipms::Error => error
    raise Refusal, error.message
  end

  private
    def requested = arguments.symbolize_keys.slice(*FIELDS)

    def prepare(changes)
      raise Refusal, problem if (problem = refusal_for(changes))
      DurableAssistants::Voipms.number_settings(account: agent.voipms_account).prepare(agent.phone_number, changes)
    end

    def refusal_for(changes)
      return "This agent has no phone number." if agent.phone_number.blank?
      return "This agent has no voip.ms account." unless agent.texts?
      return "Name at least one phone setting to change." if changes.empty?

      if (number = changes[:sms_forward]) && !number.empty? && !number.match?(/\A[0-9]{10}\z/)
        return "sms_forward must be ten digits or empty."
      end
      if (email = changes[:sms_email]) && !email.empty? && !URI::MailTo::EMAIL_REGEXP.match?(email)
        return "sms_email must be an email address or empty."
      end
      if (emails = changes[:voicemail_email]) && !emails.empty? && !email_list?(emails)
        "voicemail_email must be comma-separated email addresses or empty."
      end
    end

    def display(value) = value.empty? ? "(off or empty)" : value

    def email_list?(value)
      value.length <= 255 && !value.match?(/[\r\n]/) && value.split(",", -1).all? { URI::MailTo::EMAIL_REGEXP.match?(it.strip) }
    end
end
