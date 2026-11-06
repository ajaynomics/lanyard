class CreatePeopleAndBots < ActiveRecord::Migration[8.2]
  def change
    create_table :users do |t|
      t.string :oidc_sub, null: false, index: { unique: true }
      t.string :name, null: false, default: ""
      t.string :email, null: false, default: ""
      t.timestamps
    end

    create_table :bots do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :instructions, null: false
      t.string :model, null: false
      t.string :thinking_level, null: false, default: "medium"
      t.string :time_zone, null: false, default: "UTC"
      t.json :tool_names, null: false, default: []
      t.timestamps
    end

    create_table :bot_revisions do |t|
      t.references :bot, null: false, foreign_key: true
      t.text :instructions, null: false
      t.string :model, null: false
      t.json :tool_names, null: false, default: []
      t.datetime :created_at, null: false
    end
  end
end
