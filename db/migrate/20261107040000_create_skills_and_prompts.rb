class CreateSkillsAndPrompts < ActiveRecord::Migration[8.2]
  def change
    create_table :skills do |t|
      t.references :bot, null: false, foreign_key: true
      t.string :name, null: false
      t.string :description, null: false, limit: 1_024
      t.text :body, null: false
      t.timestamps
    end
    add_index :skills, %i[ bot_id name ], unique: true

    create_table :prompts do |t|
      t.references :bot, null: false, foreign_key: true
      t.string :name, null: false
      t.string :description, null: false, default: ""
      t.text :body, null: false
      t.timestamps
    end
    add_index :prompts, %i[ bot_id name ], unique: true

    # A revision is the whole bot at that moment, so it holds its skills and
    # saved prompts too; earlier revisions had none.
    add_column :bot_revisions, :skills, :json, default: [], null: false
    add_column :bot_revisions, :prompts, :json, default: [], null: false
  end
end
