class Agent::PilotBudget::Reservation < ApplicationRecord
  self.table_name = "pilot_budget_reservations"

  belongs_to :pilot_budget, class_name: "Agent::PilotBudget"

  validates :request_key, presence: true, length: { maximum: 128 }
  validates :maximum_cents, numericality: { only_integer: true, in: 1..Agent::PilotBudget::LIMIT }
  validates :actual_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
