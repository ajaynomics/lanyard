class User < ApplicationRecord
  has_many :agents, dependent: :destroy
  has_many :conversations, dependent: :destroy
  # Reached only through the person, so another's message is not found (AgentsController, from).
  has_many :messages, through: :conversations
  # Connectors: the person's own, for all their conversations, and each conversation's (Conversation#connectors).
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy
  # The browsers where they turned notifications on (Settings, You).
  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all
  # What the phone's Share sheet handed over, until it is sent or swept (Share).
  has_many :shares, dependent: :destroy
  has_many :campfire_rooms, dependent: :delete_all
  has_many :ahoy_visits, class_name: "Ahoy::Visit", dependent: :delete_all
  has_many :ahoy_events, class_name: "Ahoy::Event", dependent: :delete_all

  validates :oidc_sub, presence: true

  # The one path that creates people, and so the one place a new person is
  # given the starter agent. `sub` is the subject the identity provider verified.
  def self.sign_in!(sub:, email:, name:)
    return owner.tap { McpServer.install_for(it) } if Admission.owner && email.to_s.downcase != Admission.owner
    transaction do
      user = find_by(oidc_sub: sub) || claim_access_user(sub, email) || claim_owner(sub, email) || create!(oidc_sub: sub) # tenancy-ok: sign-in finds the person by the subject Ajent verified
      user.update!(email: email.to_s, name: name.to_s.presence || user.name.to_s)
      user.start_starter if user.agents.none?
      user
    end.tap { McpServer.install_for(it) }
  end

  # An install with an owner (ACCESS__OWNER_EMAIL) serves that one person:
  # everyone it admits signs in as them, to one set of agents, connectors and
  # threads, and never changes the owner's name or email. The owner's row is
  # theirs from their first sign-in, or held for them until it.
  def self.owner
    find_by(email: Admission.owner) || create!(oidc_sub: "owner:#{Admission.owner}", email: Admission.owner).tap { it.start_starter } # tenancy-ok: the install's one owner
  end

  def self.claim_owner(sub, email)
    find_by(oidc_sub: "owner:#{email.to_s.downcase}")&.tap { it.update!(oidc_sub: sub) } # tenancy-ok: the row held for the owner's first sign-in
  end

  # Cloudflare Access keyed people "cloudflare-access:<verified email>". Their
  # first sign-in under another subject (Ajent's) takes that row over, so the
  # agents, conversations and connectors they made stay theirs: the id does not
  # change. Only that exact key, never a match by email alone, and a row that
  # already has the subject wins (docs/design/PARITY.md, 45). Once everyone
  # Access made has signed in through Ajent once, this can go.
  def self.claim_access_user(sub, email)
    user = find_by(oidc_sub: "cloudflare-access:#{email.to_s.downcase}") # tenancy-ok: the one row Access made for this verified email
    user&.tap { it.update!(oidc_sub: sub) }
  end
  private_class_method :claim_access_user

  # A new agent is the install's starter (APP__STARTER_AGENT) under the name
  # the person gave it, its purpose, if they gave one, added to the starter's
  # instructions; it rewrites them itself when asked (Tool::ChangeYourself).
  # A new agent runs on the model and thinking level of the one the person
  # used last, which they know works for them (their subscription, say); the
  # starter's model only for their first, or when that model is gone.
  # Another agent's instructions (`instructions`) take the starter's place.
  def start_agent(name = nil, purpose: nil, instructions: nil, email_name: nil, title: nil)
    starter = Agent.starter(DurableAssistants.config(:app, :starter_agent))
    if (last = model_source)
      starter = starter.merge(model: last.model, thinking_level: last.thinking_level)
    end
    # Only the starter leaves the name out; a blank one the person typed is refused.
    name ||= starter[:name]
    # The starter's instructions say {{name}} where the agent's own name goes, so a new agent is not told it is the starter.
    instructions ||= starter[:instructions].gsub("{{name}}", name.to_s)
    instructions = "#{instructions}\n\n## Your purpose\n\n#{purpose.strip}" if purpose.present?
    agents.create!(starter.merge(name: name, instructions: instructions, email_name: email_name, title: title))
  end

  # "New agent from here": a whole new agent (its own name, address, computer
  # and bot), made as start_agent makes one, that carries on from another's
  # reply. It takes that agent's instructions, skills and notes, and its
  # thread starts as a copy of the other's up to the reply. Its tools,
  # connectors and model are a new agent's: the person set those for the
  # other agent's work. Made whole or not at all: a sidecar that cannot fork
  # leaves no agent behind, and the error goes on to the caller.
  def start_agent_from(message, name:, request_id:, purpose: nil, email_name: nil, title: nil)
    source = message.conversation.agent
    transaction do
      # The other agent's instructions name it; the new one is told its own name instead.
      instructions = name.present? ? source.instructions.gsub(source.name, name) : source.instructions
      start_agent(name, purpose: purpose, instructions: instructions, email_name: email_name, title: title).tap do |agent|
        agent.skills.create!(source.skills.map { it.slice(:name, :description, :body) })
        agent.notes.create!(source.notes.map { it.slice(:key, :body) })
        message.conversation.fork_into(agent.conversation, at: message, request_id: request_id)
      end
    end
  end

  # The starter is one agent: once someone has it, a later person starts with
  # none and makes their own with New agent, rather than a numbered copy
  # (Assistant 2, at assistant-2@) that could never be renamed.
  def start_starter
    start_agent unless Agent.taken?(Agent.starter(DurableAssistants.config(:app, :starter_agent))[:name])
  end

  # The agent whose thread moved last, if its model is still offered.
  def model_source
    agents.joins(:conversation).order("conversations.last_message_at": :desc, id: :desc).first
      .then { it if it&.model.in?(Agent.models) }
  end

  # The app's badge: how many agents are waiting on this person.
  def agents_needing_you = conversations.active.where(status: "waiting").distinct.count(:agent_id)

  def admin? = Admission.admin?(email)

  def to_s = name.presence || email
end
