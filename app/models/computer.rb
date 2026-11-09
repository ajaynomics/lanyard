# Where an agent's conversations run their file and shell tools
# (docs/computers.md). The agent's row is the template: on or off, the kind and the
# notes switch. Each conversation gets its own computer, made the first time it is
# used: for a Sprite, the sidecar names it `<name>-c<conversation id>`. Over
# SSH it is one folder on a real machine, worked in as one Unix user, the same
# for every conversation. Without one that is on, the conversations have no
# file or shell tools at all.
class Computer < ApplicationRecord
  STATES = %w[ off on ].freeze
  # The sidecar reads at most this much of the notes file.
  NOTES_FILE_LIMIT = 32.kilobytes
  # Short enough for a select on a phone; NOTES says the rest under it.
  LABELS = { "local" => "This machine", "sprites" => "A Sprite", "ssh" => "A machine over SSH" }.freeze
  NOTES = { "local" => "for one trusted person; not isolated", "sprites" => "its own small virtual machine",
            "ssh" => "a folder on a real machine, as one of its users; not isolated" }.freeze
  # What the sidecar accepts (agent/ssh-computers.mjs): a host name or IPv4
  # address, a Unix user name, an absolute folder without `..`.
  SSH_HOST = /\A[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\z/i
  SSH_USER = /\A[a-z_][a-z0-9_-]{0,31}\z/

  belongs_to :agent
  broadcasts_refreshes_to :agent

  # Named once the agent has its id: a starter's computer is validated with
  # the new agent, before either is saved.
  before_create :name_after_agent

  validates :provider, inclusion: { in: ->(_) { providers } }
  validates :state, inclusion: { in: STATES }
  # The prefix of the conversations' Sprite names. A Sprite name is at most 63
  # characters, so this leaves room for "-c" and the conversation id.
  validates :name, format: { with: /\A[a-z0-9][a-z0-9-]{0,49}\z/ }, unless: -> { new_record? && name.nil? }
  normalizes :ssh_host, :ssh_user, :folder, with: -> { it.strip.presence }
  # Filled in one at a time while it is off; all three before it goes on.
  with_options if: :ssh? do
    validates :ssh_host, format: { with: SSH_HOST, message: "must be a host name or an IPv4 address" }, allow_nil: true
    validates :ssh_user, format: { with: SSH_USER, message: "must be a Unix user name, such as jordan" }, allow_nil: true
    validates :folder, length: { maximum: 1024 }, format: { with: %r{\A/[^\0\n\r]*\z}, message: "must start with /" }, allow_nil: true
    validate :folder_stays_put
  end
  validates :ssh_host, :ssh_user, :folder, presence: true, if: -> { ssh? && on? }

  # The kinds of computer this environment may use (config/pi_durable.yml).
  # The sidecar refuses one it cannot provide as well.
  def self.providers
    DurableAssistants.config(:pi_durable, :computers, default: [])
  end

  def on? = state == "on"

  def sprites? = provider == "sprites"

  def ssh? = provider == "ssh"

  # Where an SSH computer works, as a person would type it: jordan@homeserver:/home/jordan/work.
  def ssh_address = ("#{ssh_user}@#{ssh_host}:#{folder}" if ssh? && ssh_host && ssh_user && folder)

  # What the sidecar receives in the agent's definition. The notes file switch
  # is in it, so turning it on or off reconfigures the agent like any edit.
  def descriptor
    return unless on?
    where = if sprites? then { provider: "sprites", name: name }
    elsif ssh? then { provider: "ssh", host: ssh_host, user: ssh_user, folder: folder }
    else { provider: "local" }
    end
    where.merge(notesFile: notes_file)
  end

  private
    def folder_stays_put
      errors.add(:folder, "can't use ..") if folder.to_s.split("/").include?("..")
    end

    def name_after_agent
      # DEPLOYMENT_ENVIRONMENT tells staging from production; both run RAILS_ENV=production.
      # The "b" and the number are an opaque identifier of a live Sprite (it was
      # the bot's id before the rename): never rebuild it from another prefix.
      # The prefix names this deployment's Sprites on the platform.
      self.name ||= "#{DurableAssistants.config(:pi_durable, :sprite_prefix)}-#{ENV.fetch('DEPLOYMENT_ENVIRONMENT', Rails.env)}-b#{agent_id}"
    end
end
