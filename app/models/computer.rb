# Where a bot's file and shell tools run (docs/agent.md). One per bot; each
# conversation works in its own directory on it. Without one that is on, the
# bot has no file or shell tools at all.
class Computer < ApplicationRecord
  STATES = %w[ off on ].freeze
  LABELS = { "local" => "This machine (one trusted person; not isolated)",
             "sprites" => "A Sprite: its own small virtual machine" }.freeze

  belongs_to :bot

  before_validation :name_after_bot, on: :create

  validates :provider, inclusion: { in: ->(_) { providers } }
  validates :state, inclusion: { in: STATES }
  # A Sprite's name, unique in the Sprites account.
  validates :name, format: { with: /\A[a-z0-9][a-z0-9-]{0,62}\z/ }

  # The kinds of computer this environment may use (config/pi_durable.yml).
  # The sidecar refuses one it cannot provide as well.
  def self.providers
    DurableAssistants.config(:pi_durable, :computers, default: [])
  end

  def on? = state == "on"

  # What the sidecar receives in the bot's definition.
  def descriptor
    return unless on?
    provider == "sprites" ? { provider: "sprites", name: name } : { provider: "local" }
  end

  private
    def name_after_bot
      # DEPLOYMENT_ENVIRONMENT tells staging from production; both run RAILS_ENV=production.
      self.name ||= "avery-#{ENV.fetch('DEPLOYMENT_ENVIRONMENT', Rails.env)}-bot-#{bot_id}"
    end
end
