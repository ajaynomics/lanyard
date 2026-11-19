# A workspace's shared instructions, which every one of its agents follows
# beside its own; each change kept as a revision naming who made it and who
# proposed it, and members' proposals waiting for the owner. A column with a
# default and two new tables: code from before, during a rolling deploy or
# after a rollback, reads none of them. A revision outlives the person or
# agent it names, forgetting only who; a proposal goes with its proposer.
class AddInstructionsToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :instructions, :text, default: "", null: false

    create_table :workspace_revisions do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.text :instructions, null: false
      t.references :changed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :proposed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :proposed_by_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.datetime :created_at, null: false
    end

    create_table :workspace_proposals do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :proposed_by, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.text :instructions, null: false
      t.timestamps
    end
  end
end
