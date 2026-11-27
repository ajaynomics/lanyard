class Approval < ApplicationRecord
  DECISIONS = %w[ approve deny ].freeze

  belongs_to :invocation
  belongs_to :decided_by, class_name: "User"

  validates :decision, inclusion: { in: DECISIONS }

  def kind = invocation.approval_kind.to_s
end
