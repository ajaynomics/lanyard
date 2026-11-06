class Bot < ApplicationRecord
  THINKING_LEVELS = %w[ low medium high ].freeze

  belongs_to :user
  has_many :revisions, dependent: :delete_all
  has_many :conversations, dependent: :destroy
  has_many :notes, dependent: :delete_all

  validates :name, :instructions, presence: true
  validates :model, inclusion: { in: ->(_) { models } }
  validates :thinking_level, inclusion: { in: THINKING_LEVELS }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) + %w[ UTC ] }
  validate :tools_are_catalogued

  # History cannot be added later: a table created in March knows nothing of
  # February. Restoring a revision is not built yet.
  after_save :record_revision, if: -> { saved_change_to_instructions? || saved_change_to_model? || saved_change_to_tool_names? }

  # The model routes the sidecar will run, per environment (config/pi_durable.yml).
  def self.models
    DurableAssistants.config(:pi_durable, :models, default: [])
  end

  # A starter bot's reviewed defaults: config/bots/<name>/bot.yml and its
  # instructions.md. The created record is then the live bot.
  def self.starter(name)
    directory = Rails.root.join("config/bots", name.to_s)
    settings = YAML.safe_load_file(directory.join("bot.yml"))
    { name: settings.fetch("name"), tool_names: settings.fetch("tools"),
      model: DurableAssistants.config(:pi_durable, :default_model, default: settings.fetch("model")),
      instructions: directory.join("instructions.md").read.strip }
  end

  # The tool classes this bot may call. A stored name with no class is
  # refused by validation, and by the ledger if it slipped past.
  def tools
    tool_names.filter_map { Tool::Catalog.find(it) }
  end

  def tool(name)
    tools.find { it.tool_name == name }
  end

  # Everything the sidecar runs this bot on, named by its own digest, so the
  # sidecar installs each definition once and never caches a stale one.
  def definition
    body = { instructions: instructions, model: model, thinkingLevel: thinking_level, tools: tools.map(&:declaration) }
    body.merge(digest: Agent::Canonical.digest(body))
  end

  # The bot's working directory on the stand-in computer. Stable for the
  # bot's lifetime: the sidecar binds each conversation to it at admission.
  def workdir
    Rails.root.join("storage/agent/computers", "bot-#{id}").to_s
  end

  def start_conversation(request_id:)
    durable_id = DurableAssistants::PiDurable::Client.new.conversation(Agent::Access.for(self), request_id).fetch("id").to_s
    conversation = conversations.create_or_find_by!(request_id: request_id) { it.user = user; it.durable_id = durable_id }
    # A sidecar conversation recorded under another request means the store and
    # this database are not from one point in time; refuse rather than guess.
    raise Conversation::Mismatch unless conversation.durable_id == durable_id
    conversation
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotFound
    raise Conversation::Mismatch
  end

  def to_s = name

  private
    def tools_are_catalogued
      (Array(tool_names) - Tool::Catalog.names).each { errors.add(:tool_names, "includes #{it}, which is not a tool") }
    end

    def record_revision
      revisions.create!(instructions: instructions, model: model, tool_names: tool_names)
    end
end
