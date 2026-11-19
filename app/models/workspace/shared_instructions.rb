# What every agent of the workspace follows, beside its own instructions.
# Only its owner changes them: directly, or by accepting a member's proposal
# (Workspace::Proposal) or allowing an agent's (change_yourself with scope
# "workspace"). Each change is kept with who made it and who proposed it.
module Workspace::SharedInstructions
  extend ActiveSupport::Concern

  LIMIT = 32_768
  PROMPT_HEADING = "## Your workspace's shared instructions"

  included do
    has_many :revisions, -> { order(id: :desc) }, dependent: :delete_all
    has_many :proposals, -> { order(:id) }, dependent: :delete_all

    normalizes :instructions, with: -> { it.strip }
    validates :instructions, length: { maximum: LIMIT }
  end

  # `proposed_by` is the person or agent whose proposal this was, if anyone's.
  def change_instructions(text, by:, proposed_by: nil)
    transaction do
      update!(instructions: text)
      revisions.create!(instructions: instructions, changed_by: by,
        proposed_by: (proposed_by if proposed_by.is_a?(User)), proposed_by_agent: (proposed_by if proposed_by.is_a?(Agent)))
    end
  end

  # As its agents' models read them, after their own instructions: labelled,
  # so a model knows whose they are and how a change to them is asked for.
  def instructions_prompt
    return "" if instructions.blank?
    "\n\n#{PROMPT_HEADING}\n\nEvery agent in #{self} follows these, beside your own instructions above. Only its owner changes them; " \
      "to suggest a change, call change_yourself with scope \"workspace\".\n\n#{instructions}"
  end
end
