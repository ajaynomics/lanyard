class CreateComputers < ActiveRecord::Migration[8.2]
  def change
    create_table :computers do |t|
      t.references :bot, null: false, foreign_key: true, index: { unique: true }
      t.string :provider, null: false, default: "local"
      t.string :name, null: false
      t.string :state, null: false, default: "off"
      t.timestamps
    end
  end
end
