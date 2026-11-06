class User < ApplicationRecord
  STARTER_BOT = :avery

  has_many :bots, dependent: :destroy
  has_many :conversations, dependent: :destroy

  validates :oidc_sub, presence: true

  # Ajent says who someone is; this list says who may use the app. Each bot
  # call can cost money, so an unlisted address is turned away.
  def self.admitted?(email)
    email.present? && DurableAssistants.config(:access, :emails, default: []).include?(email.downcase)
  end

  # The one path that creates people, and so the one place a new person is
  # given the starter bot. `sub` is the subject the identity provider verified.
  def self.sign_in!(sub:, email:, name:)
    transaction do
      user = find_or_create_by!(oidc_sub: sub) # tenancy-ok: sign-in finds the person by the subject Ajent verified
      user.update!(email: email.to_s, name: name.to_s.presence || user.name.to_s)
      user.bots.create!(Bot.starter(STARTER_BOT)) if user.bots.none?
      user
    end
  end

  def to_s = name.presence || email
end
