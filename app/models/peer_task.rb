# A Concourse task, linked to the conversation it belongs to:
# `inbound`, a peer's request this conversation may
# answer with concourse_reply, or `outbound`, one it sent with concourse_send,
# whose answers come back to it as a follow-up.
class PeerTask < ApplicationRecord
  DIRECTIONS = %w[ inbound outbound ].freeze
  TERMINAL = %w[ TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_REJECTED TASK_STATE_CANCELED ].freeze
  TEXT_LIMIT = 50_000

  belongs_to :conversation
  # The identity, and so the network, it came or went on: blank for a task
  # from before networks, which is the first identity's. One whose identity
  # was disconnected has none, and can no longer be acted on.
  belongs_to :concourse_agent, optional: true
  broadcasts_refreshes_to ->(task) { task.conversation.agent }

  validates :task_id, :peer, :state, presence: true
  validates :direction, inclusion: { in: DIRECTIONS }

  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }
  scope :open, -> { where.not(state: TERMINAL) }

  # A Concourse task as the model reads it: who, where it stands, and the
  # words, never the wire's whole shape.
  def self.summary(task)
    { taskId: task["id"], contextId: task["contextId"], state: task.dig("status", "state"),
      from: task.dig("metadata", "concourse.caller"),
      messages: Array(task["history"]).map { { role: it["role"] == "ROLE_USER" ? "caller" : "recipient", text: text_of(it) } },
      answer: (text_of(task.dig("status", "message")) if task.dig("status", "message", "role") == "ROLE_AGENT").presence,
      artifacts: Array(task["artifacts"]).map { text_of(it) }.compact_blank.presence }.compact
  end

  # Text parts as text; structured data as JSON; anything else is named.
  def self.text_of(message)
    Array(message&.dig("parts")).map do |part|
      if part["text"].is_a?(String) then part["text"]
      elsif part.key?("data") then part["data"].to_json
      else "[#{part["mediaType"] || "file"} #{part["filename"]}]".squish
      end
    end.join("\n\n").truncate(TEXT_LIMIT)
  end

  # Where it stands, in words: "TASK_STATE_INPUT_REQUIRED" is "Asks a question".
  STATES = { "TASK_STATE_SUBMITTED" => "Sent", "TASK_STATE_WORKING" => "Working", "TASK_STATE_INPUT_REQUIRED" => "Asks a question",
             "TASK_STATE_AUTH_REQUIRED" => "Needs a sign-in" }.freeze

  def state_words = STATES.fetch(state) { state.delete_prefix("TASK_STATE_").humanize }

  def terminal? = TERMINAL.include?(state)

  def channel = concourse_agent_id ? concourse_agent : conversation.agent.concourse_agent

  def delivered?(id) = delivered_ids.include?(id)

  def deliver(id)
    update!(delivered_ids: delivered_ids + [ id ]) unless delivered?(id)
  end
end
