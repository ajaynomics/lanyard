# Another install moved in as a shared workspace (Workspace::Import,
# docs/import.md): which copy came, at which release, and what came of it. The
# copy's digest is unique, so the same copy never comes in twice. A new table:
# a release running beside this one during a rolling deploy neither reads nor
# writes it, and no existing row changes.
class CreateWorkspaceImports < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_imports do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :source_digest, null: false, index: { unique: true }
      t.string :source_version, null: false
      t.json :report, default: {}, null: false
      t.timestamps
    end
  end
end
