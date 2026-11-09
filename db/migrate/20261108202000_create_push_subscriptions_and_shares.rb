# Each browser the person turned notifications on in, and
# what the phone's Share sheet handed over until the person sends it.
class CreatePushSubscriptionsAndShares < ActiveRecord::Migration[8.2]
  def change
    create_table :push_subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false
      t.string :user_agent, null: false, default: ""
      t.timestamps
      t.index :endpoint, unique: true
    end

    create_table :shares do |t|
      t.references :user, null: false, foreign_key: true
      t.text :text, null: false, default: ""
      t.timestamps
      t.index :created_at
    end
  end
end
