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
  argument :title, :string, required: false, max_length: Agent::TITLE_LIMIT, description: "What it does, shown beside its name: \"Personal Assistant\"."
  argument :address, :string, required: false, max_length: 64, pattern: "^[A-Za-z0-9._-]+@?$",
    description: "The part of its email address before @. Left out, it comes from the name."
  argument :purpose, :string, required: false, max_length: 4000, description: "What it is for; it starts its instructions."
  asks :approval, always: false

  # What will be made, in the words the person approves.
  def self.approval_title(arguments)
    name = arguments["name"].to_s.squish
    name = "#{name} (#{arguments["title"].squish})" if arguments["title"].present?
    address = Agent.new(email_name: arguments["address"]).email_name || Agent.email_name_for(name)
    at = " at #{address}@#{DurableAssistants::Email.domain}" if DurableAssistants::Email.configured?
    bot = " and Campfire bot" if DurableAssistants::Campfire.admin?
    "Make #{name}#{at}, a permanent agent with its own computer#{bot}?"
  end

  # Nothing in the result sends the new agent to Concourse: only an agent the
  # person asks to join goes there (Tool::JoinConcourse), so an install can keep
  # one agent as its gateway.
  def call(name:, title: nil, address: nil, purpose: nil)
    made = user.start_agent(name.squish, title: title, purpose: purpose, email_name: address)
    { made: made.name, title: made.title, address: made.email_address || made.email_name,
      thread: Rails.application.routes.url_helpers.conversation_path(made.conversation) }.compact
  rescue ActiveRecord::RecordInvalid => invalid
    raise Refusal, invalid.record.errors.full_messages.to_sentence
  end
end
