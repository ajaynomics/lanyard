class User < ApplicationRecord
  STARTER_BOT = :durable_assistants

  has_many :bots, dependent: :destroy
  has_many :conversations, dependent: :destroy
  # Connectors: the person's own, for all their agents, and each agent's (Conversation#connectors).
  has_many :mcp_servers, -> { order(:name) }, dependent: :destroy

  validates :oidc_sub, presence: true

  # The one path that creates people, and so the one place a new person is
  # given the starter bot. `sub` is the subject the identity provider verified.
  def self.sign_in!(sub:, email:, name:)
    transaction do
      user = find_by(oidc_sub: sub) || claim_access_user(sub, email) || create!(oidc_sub: sub) # tenancy-ok: sign-in finds the person by the subject Ajent verified
      user.update!(email: email.to_s, name: name.to_s.presence || user.name.to_s)
      user.bots.create!(Bot.starter(STARTER_BOT)) if user.bots.none?
      user
    end
  end

  # Cloudflare Access keyed people "cloudflare-access:<verified email>". Their
  # first sign-in under another subject (Ajent's) takes that row over, so the
  # bots, conversations and connectors they made stay theirs: the id does not
  # change. Only that exact key, never a match by email alone, and a row that
  # already has the subject wins (docs/design/PARITY.md, 45).
  def self.claim_access_user(sub, email)
    user = find_by(oidc_sub: "cloudflare-access:#{email.to_s.downcase}") # tenancy-ok: the one row Access made for this verified email
    user&.tap { it.update!(oidc_sub: sub) }
  end
  private_class_method :claim_access_user

  def to_s = name.presence || email
end
