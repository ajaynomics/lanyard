class Agent::Revision < ApplicationRecord
  include InstructionRevision

  belongs_to :agent
  belongs_to :invocation, optional: true
  belongs_to :instruction_workspace, class_name: "Workspace", optional: true
  belongs_to :restored_by, class_name: "User", optional: true
  belongs_to :restored_from, class_name: name, optional: true

  # What an approval of this revision covers: the agent, in the workspace it was in then.
  def approved_place = [ agent, instruction_workspace ]

  private
    def proposed_digest
      restored_from ? restored_from.approved_digest : super
    end
end
