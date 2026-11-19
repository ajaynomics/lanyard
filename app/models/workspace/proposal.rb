# A member's proposed new text for the workspace's shared instructions,
# waiting for its owner, who accepts it or declines it; its proposer may
# withdraw it. An agent's proposal is a change_yourself card instead.
class Workspace::Proposal < ApplicationRecord
  belongs_to :workspace
  belongs_to :proposed_by, class_name: "User"

  normalizes :instructions, with: -> { it.strip }
  validates :instructions, length: { maximum: Workspace::SharedInstructions::LIMIT }
  validate :changes_something, on: :create

  def change = InstructionsChange.new(workspace.instructions, instructions)

  def accept(by:)
    transaction do
      workspace.change_instructions(instructions, by: by, proposed_by: proposed_by)
      destroy!
    end
  end

  def withdrawable_by?(person) = person == proposed_by || person == workspace.owner

  private
    def changes_something
      errors.add(:instructions, "are the same as now") if instructions == workspace.instructions
    end
end
