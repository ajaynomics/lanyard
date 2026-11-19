# Each iPhone where the phone app turned notifications on: the token Apple's
# push service gave it, and which of Apple's services that token belongs to.
class CreatePushDevices < ActiveRecord::Migration[8.2]
  def change
    create_table :push_devices do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token, null: false
      t.string :environment, null: false, default: "production"
      t.timestamps
      t.index :token, unique: true
    end
  end
end
