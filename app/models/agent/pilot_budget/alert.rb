class Agent::PilotBudget::Alert < ApplicationRecord
  self.table_name = "pilot_budget_alerts"

  belongs_to :pilot_budget, class_name: "Agent::PilotBudget"

  validates :threshold, inclusion: { in: Agent::PilotBudget::THRESHOLDS }
end
