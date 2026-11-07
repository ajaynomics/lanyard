# Where a bot's agents (its conversations) run their file and shell tools
# (docs/agent.md). The bot's row is the template: on or off, the kind and the
# notes switch. Each agent gets its own computer, made the first time it is
# used: for a Sprite, the sidecar names it `<name>-c<conversation id>`. Without
# one that is on, the agents have no file or shell tools at all.
class Computer < ApplicationRecord
  STATES = %w[ off on ].freeze
  # The sidecar reads at most this much of the notes file.
  NOTES_FILE_LIMIT = 32.kilobytes
  LABELS = { "local" => "This machine (one trusted person; not isolated)",
             "sprites" => "A Sprite: its own small virtual machine" }.freeze

  belongs_to :bot

  before_validation :name_after_bot, on: :create

  validates :provider, inclusion: { in: ->(_) { providers } }
  validates :state, inclusion: { in: STATES }
  # The prefix of the agents' Sprite names. A Sprite name is at most 63
  # characters, so this leaves room for "-c" and the conversation id.
  validates :name, format: { with: /\A[a-z0-9][a-z0-9-]{0,49}\z/ }

  # The kinds of computer this environment may use (config/pi_durable.yml).
  # The sidecar refuses one it cannot provide as well.
  def self.providers
    DurableAssistants.config(:pi_durable, :computers, default: [])
  end

  def on? = state == "on"

  def sprites? = provider == "sprites"

  # What the sidecar receives in the bot's definition. The notes file switch
  # is in it, so turning it on or off reconfigures the bot like any edit.
  def descriptor
    return unless on?
    (sprites? ? { provider: "sprites", name: name } : { provider: "local" }).merge(notesFile: notes_file)
  end

  private
    def name_after_bot
      # DEPLOYMENT_ENVIRONMENT tells staging from production; both run RAILS_ENV=production.
      self.name ||= "avery-#{ENV.fetch('DEPLOYMENT_ENVIRONMENT', Rails.env)}-b#{bot_id}"
    end
end
