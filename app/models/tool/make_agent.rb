# An agent makes another, as New agent does, when the person asks (a chief of
# staff makes the people under her). The result is permanent: its name and
# address can't change, and it has its own computer and, where the install can
# make one, its own Campfire bot. So the person approves exactly what will be
# made, every time. Off unless switched on for the agent; there is no tool to
# delete one.
class Tool::MakeAgent < Tool
  description "Make a new agent for the person you work for, when they ask: a permanent colleague with its own name, " \
    "email address, computer and memory. Its name and address can't be changed later. The person approves exactly " \
    "what will be made first. Write its purpose as its first instructions."
  argument :name, :string, min_length: 1, max_length: 200
  argument :address, :string, required: false, max_length: 64, pattern: "^[A-Za-z0-9._-]+@?$",
    description: "The part of its email address before @. Left out, it comes from the name."
  argument :purpose, :string, required: false, max_length: 4000, description: "What it is for; it starts its instructions."
  asks :approval, always: false

  # What will be made, in the words the person approves.
  def self.approval_title(arguments)
    name = arguments["name"].to_s.squish
    address = Agent.new(email_name: arguments["address"]).email_name || Agent.email_name_for(name)
    at = " at #{address}@#{DurableAssistants::Email.domain}" if DurableAssistants::Email.configured?
    bot = " and Campfire bot" if DurableAssistants::Campfire.admin?
    "Make #{name}#{at}, a permanent agent with its own computer#{bot}?"
  end

  def call(name:, address: nil, purpose: nil)
    made = user.start_agent(name.squish, purpose: purpose, email_name: address)
    { made: made.name, address: made.email_address || made.email_name, thread: Rails.application.routes.url_helpers.conversation_path(made.conversation) }
  rescue ActiveRecord::RecordInvalid => invalid
    raise Refusal, invalid.record.errors.full_messages.to_sentence
  end
end
