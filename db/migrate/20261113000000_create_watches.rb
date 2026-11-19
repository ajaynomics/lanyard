# Each Apple Watch a person reaches the app from, with the digest of its own
# token: never the token itself.
class CreateWatches < ActiveRecord::Migration[8.2]
  def change
    create_table :watches do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
      t.index :token_digest, unique: true
    end
  end
end
