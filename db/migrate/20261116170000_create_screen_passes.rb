# One-time links to a conversation's screen, for someone not signed in here
# (ScreenPass). Only the token's digest is kept. A new table, so code from
# before, running during a rolling deploy or after a rollback, neither reads
# nor writes it; its keys cascade, so that code can still delete the
# conversation or person it belongs to.
class CreateScreenPasses < ActiveRecord::Migration[8.2]
  def change
    create_table :screen_passes do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :token_digest, null: false, index: { unique: true }
      t.string :viewer_digest
      t.datetime :expires_at, null: false
      t.datetime :opened_at
      t.datetime :ended_at
      t.timestamps
    end
  end
end
