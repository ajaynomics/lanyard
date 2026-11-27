# Who allowed each instruction revision, from which call, and the
# digest of the text that person approved (docs/permissions.md). Safe across a
# rolling deploy: every column is nullable and nothing from before reads or
# writes it, so an existing revision keeps its text and records no approval.
class AddInstructionProvenanceToRevisions < ActiveRecord::Migration[8.2]
  def change
    %i[ agent_revisions workspace_revisions ].each do |table|
      add_reference table, :approval, foreign_key: { on_delete: :nullify }
      add_column table, :approved_digest, :string
    end
    add_reference :agent_revisions, :instruction_workspace, foreign_key: { to_table: :workspaces, on_delete: :nullify }
    add_reference :agent_revisions, :invocation, foreign_key: { on_delete: :nullify }
  end
end
