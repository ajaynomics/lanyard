# What a workspace's model calls used (docs/billing.md): the tokens each
# model or tool added in a run or a background helper, recorded as it ends,
# against the workspace and agent that made the calls and the workspace they
# were billed to then (nil: the install). A record is never worked out again
# from settings that change later: moving who pays changes only the calls
# after. The cost is the catalogue's estimate at API prices, never a bill.
class ModelUsage < ApplicationRecord
  belongs_to :workspace
  belongs_to :agent, optional: true
  belongs_to :conversation, optional: true
  belongs_to :helper, optional: true
  belongs_to :payer, class_name: "Workspace", optional: true

  validates :agent_name, presence: true
  validate :a_model_or_a_tool

  scope :during, ->(times) { where(created_at: times) }

  # One record for each model and tool in `rows` (Usage.rows) that used more
  # than `before` says it had, made by the agent, billed to its workspace's
  # payer. `source` names the thread or helper and the file it was filed under.
  def self.record(agent, rows, before: nil, **source)
    rows.each do |kind, named|
      named.each do |name, now|
        added = now.to_h { |key, value| [ key, value - (before&.dig(kind, name, key) || 0) ] }
        next unless added["totalTokens"].positive?
        agent.workspace.model_usages.create!(agent: agent, agent_name: agent.name, payer: agent.workspace.payer,
          (kind == "models" ? :model : :tool) => name, input: added["input"], output: added["output"],
          cache_read: added["cacheRead"], cache_write: added["cacheWrite"], total_tokens: added["totalTokens"],
          cost: (added["cost"].round(6) if added["cost"].positive?), **source)
      end
    end
  end

  private
    def a_model_or_a_tool
      errors.add(:base, "names a model or a tool") unless model.present? ^ tool.present?
    end
end
