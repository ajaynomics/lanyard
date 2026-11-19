# A document may be deleted softly (Document::Deletable): when and by whom,
# the agent or a person, as a version says who wrote it. Every document here
# stays undeleted. A title is unique among the undeleted alone, so a deleted
# one's title is free again; code from before deletes nothing, so during a
# rolling deploy the narrower index holds exactly the rows the old one did.
class AddDeletedAtToDocuments < ActiveRecord::Migration[8.2]
  def change
    add_column :documents, :deleted_at, :datetime
    add_column :documents, :deleted_by, :string
    add_index :documents, :deleted_at
    remove_index :documents, [ :agent_id, :title ], unique: true
    add_index :documents, [ :agent_id, :title ], unique: true, where: "deleted_at IS NULL"
  end
end
