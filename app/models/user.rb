class User < ApplicationRecord
  has_many :agents, dependent: :destroy
  has_many :conversations, dependent: :destroy
  # Connectors: the person's own, for all their conversations, and each conversation's (Conversation#connectors).
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy

  validates :oidc_sub, presence: true

  # The one path that creates people, and so the one place a new person is
  # given the starter agent. `sub` is the subject the identity provider verified.
  def self.sign_in!(sub:, email:, name:)
    transaction do
      user = find_by(oidc_sub: sub) || claim_access_user(sub, email) || create!(oidc_sub: sub) # tenancy-ok: sign-in finds the person by the subject Ajent verified
      user.update!(email: email.to_s, name: name.to_s.presence || user.name.to_s)
      user.start_agent if user.agents.none?
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
  def start_agent(name = nil, purpose: nil)
    starter = Agent.starter(DurableAssistants.config(:app, :starter_agent))
    instructions = purpose.present? ? "#{starter[:instructions]}\n\n## Your purpose\n\n#{purpose.strip}" : starter[:instructions]
    # Only sign-in leaves the name out; a blank one the person typed is refused.
    agents.create!(starter.merge(name: name || starter[:name], instructions: instructions))
  end

  def admin? = Admission.admin?(email)

  def to_s = name.presence || email
end
