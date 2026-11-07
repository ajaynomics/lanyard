# Where an agent's conversations run their file and shell tools
# (docs/agent.md). The agent's row is the template: on or off, the kind and the
# notes switch. Each conversation gets its own computer, made the first time it is
# used: for a Sprite, the sidecar names it `<name>-c<conversation id>`. Without
# one that is on, the conversations have no file or shell tools at all.
class Computer < ApplicationRecord
  STATES = %w[ off on ].freeze
  # The sidecar reads at most this much of the notes file.
  NOTES_FILE_LIMIT = 32.kilobytes
  LABELS = { "local" => "This machine (one trusted person; not isolated)",
             "sprites" => "A Sprite: its own small virtual machine" }.freeze

  belongs_to :agent

  before_validation :name_after_agent, on: :create

  validates :provider, inclusion: { in: ->(_) { providers } }
  validates :state, inclusion: { in: STATES }
  # The prefix of the conversations' Sprite names. A Sprite name is at most 63
  # characters, so this leaves room for "-c" and the conversation id.
  validates :name, format: { with: /\A[a-z0-9][a-z0-9-]{0,49}\z/ }

  # The kinds of computer this environment may use (config/pi_durable.yml).
  # The sidecar refuses one it cannot provide as well.
  def self.providers
    DurableAssistants.config(:pi_durable, :computers, default: [])
  end

  def on? = state == "on"

  def sprites? = provider == "sprites"

  # What the sidecar receives in the agent's definition. The notes file switch
  # is in it, so turning it on or off reconfigures the agent like any edit.
  def descriptor
    return unless on?
    (sprites? ? { provider: "sprites", name: name } : { provider: "local" }).merge(notesFile: notes_file)
  end

  private
    def name_after_agent
      # DEPLOYMENT_ENVIRONMENT tells staging from production; both run RAILS_ENV=production.
      # The "b" and the number are an opaque identifier of a live Sprite (it was
      # the bot's id before the rename): never rebuild it from another prefix.
      self.name ||= "avery-#{ENV.fetch('DEPLOYMENT_ENVIRONMENT', Rails.env)}-b#{agent_id}"
    end
end
