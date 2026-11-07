# A bot's identity on Concourse, the agents' mail network (docs/design/PARITY.md
# §26). The Concourse operator binds a machine client to one named agent in one
# organization (for Avery, `avery/durable-assistants` in `avery`); the owner pastes its
# id and secret here. Access tokens are never stored here, only in Rails.cache
# (DurableAssistants::Concourse::Client). `cursor` is where the inbox sweep goes on
# reading further back.
class ConcourseAgent < ApplicationRecord
  belongs_to :bot

  encrypts :client_secret

  normalizes :organization, :handle, :client_id, :client_secret, with: -> { it.strip.presence }
  validates :organization, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/, message: "must look like avery" }
  validates :handle, format: { with: DurableAssistants::Concourse::Client::HANDLE, message: "must look like avery/durable-assistants" }
  validates :client_id, :client_secret, presence: true

  def client
    DurableAssistants::Concourse::Client.new(organization: organization, handle: handle, client_id: client_id, client_secret: client_secret)
  end

  # Asks Concourse who these credentials are, and keeps the answer for the page.
  def check
    client.identity
    update!(checked_at: Time.current, check_error: nil)
    true
  rescue DurableAssistants::Concourse::Client::Error => problem
    update!(checked_at: Time.current, check_error: problem.message.truncate(500))
    false
  end

  def connected? = checked_at.present? && check_error.nil?

  def to_s = "#{handle} in #{organization}"
end
