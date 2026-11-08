class CreateDocumentVersions < ActiveRecord::Migration[8.2]
  def change
    create_table :document_versions do |t|
      t.references :document, null: false, foreign_key: true
      t.integer :number, null: false
      t.text :body, null: false
      t.string :author, null: false
      t.timestamps
      t.index %i[ document_id number ], unique: true
    end
  end
end
