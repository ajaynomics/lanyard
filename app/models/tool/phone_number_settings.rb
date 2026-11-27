class Tool::PhoneNumberSettings < Tool
  description "Read voip.ms settings for your phone number or another number on your workspace's account, or list that account's numbers. " \
    "Shows routing, voicemail and SMS forwarding without passwords or callback URLs."
  argument :number, :string, required: false, pattern: "^[0-9]{10}$", min_length: 10, max_length: 10, description: "Ten digits. Omit to read your own number."
  argument :list, :boolean, required: false, description: "Set true to list the account's numbers and their SMS forwarding and routing. Omit number when listing."
  effect :external

  def refusal
    return "Choose either list or a phone number, not both." if arguments["list"] && arguments["number"]
    return "This agent has no phone number." if !arguments["list"] && !arguments["number"] && agent.phone_number.blank?
    "This agent has no voip.ms account." unless DurableAssistants::Voipms.configured?(agent.voipms_account)
  end

  def call(number: nil, list: false)
    raise Refusal, problem if (problem = refusal)
    settings = DurableAssistants::Voipms.number_settings(account: agent.voipms_account)
    list ? { numbers: settings.list } : settings.read(number || agent.phone_number)
  rescue DurableAssistants::Voipms::Error => error
    raise Refusal, error.message
  end
end
