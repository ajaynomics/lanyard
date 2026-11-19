# A workspace's own address and key for one of the install's connectors
# (Workspace::InstallConnector), the key encrypted. A new table, so every
# existing workspace keeps the install's, and code from before neither reads
# nor writes it; its key cascades, so that code can still delete a workspace.
class CreateWorkspaceInstallConnectors < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_install_connectors do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.string :url
      t.text :api_key, null: false
      t.timestamps
      t.index %i[ workspace_id name ], unique: true
    end
  end
end
