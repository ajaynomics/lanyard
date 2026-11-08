class CreateDocuments < ActiveRecord::Migration[8.2]
  def change
    create_table :documents do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :title, null: false
      t.string :kind, null: false, default: "markdown"
      t.string :language
      # The version the agent last saw. No foreign key: a document's versions go before it does.
      t.integer :seen_version_id
      t.timestamps
      t.index %i[ agent_id title ], unique: true
    end
  end
end
