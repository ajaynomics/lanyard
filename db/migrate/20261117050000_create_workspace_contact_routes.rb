# Who answers which outside contact in a workspace (Workspace::ContactRoute).
# A new table, so code from before, running during a rolling deploy or after a
# rollback, neither reads nor writes it; its keys cascade, so that code can
# still delete the workspace or the agent it names.
class CreateWorkspaceContactRoutes < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_contact_routes do |t|
      t.references :workspace, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.string :contact, null: false
      t.timestamps
    end
    add_index :workspace_contact_routes, %i[ workspace_id contact ], unique: true
  end
end
