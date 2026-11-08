class User < ApplicationRecord
  has_many :agents, dependent: :destroy
  has_many :conversations, dependent: :destroy
  # Connectors: the person's own, for all their conversations, and each conversation's (Conversation#connectors).
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy
  # The browsers where they turned notifications on (Settings, You).
  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all
  # What the phone's Share sheet handed over, until it is sent or swept (Share).
  has_many :shares, dependent: :destroy
  has_many :ahoy_visits, class_name: "Ahoy::Visit", dependent: :delete_all
  has_many :ahoy_events, class_name: "Ahoy::Event", dependent: :delete_all

  validates :oidc_sub, presence: true

  # The one path that creates people, and so the one place a new person is
  # given the starter agent. `sub` is the subject the identity provider verified.
  def self.sign_in!(sub:, email:, name:)
    transaction do
      user = find_by(oidc_sub: sub) || claim_access_user(sub, email) || create!(oidc_sub: sub) # tenancy-ok: sign-in finds the person by the subject Ajent verified
      user.update!(email: email.to_s, name: name.to_s.presence || user.name.to_s)
      user.start_starter if user.agents.none?
      user
    end.tap { McpServer.install_for(it) }
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
  def start_agent(name = nil, purpose: nil)
    starter = Agent.starter(DurableAssistants.config(:app, :starter_agent))
    if (last = model_source)
      starter = starter.merge(model: last.model, thinking_level: last.thinking_level)
    end
    instructions = purpose.present? ? "#{starter[:instructions]}\n\n## Your purpose\n\n#{purpose.strip}" : starter[:instructions]
    # Only the starter leaves the name out; a blank one the person typed is refused.
    agents.create!(starter.merge(name: name || starter[:name], instructions: instructions))
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
